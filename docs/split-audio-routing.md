# Split Audio Routing — Design Review

Status: **approved — decisions locked 2026-10-31**
Related: `docs/per-app-routing-design.mmd` (architecture diagram)

## Decisions (from review)

1. **Audio focus first.** ~85 ms replay latency is acceptable; the
   smaller-buffer knob is deferred (phase 4 nice-to-have, not a blocker).
2. **Route picker stays in the compact notch row, but tapping it expands
   the panel** — the per-source device menu renders in the expanded
   layout where there is room for device names and status.
3. **macOS 26 only.** The app deployment target is 26.0; use
   `CATapDescription.processRestoreEnabled` and other 26-era tap APIs
   directly, no pre-26 fallback paths. The `Nook` package itself keeps
   its existing platform floor (upstream compat).

## Goal

Route one app's audio to one output device and another app's audio to a
different device, simultaneously — e.g. Spotify → AirPods while Firefox →
MacBook speakers. A routed source must play **only** on its chosen device
(no echo on the system default), and unrouted sources must behave exactly
as macOS does today.

## Current state

The repo already implements most of the architecture:

| Piece | File | State |
| --- | --- | --- |
| Per-source capture | `ProcessAudioTap.swift` (`AudioHardwareCreateProcessTap` + private aggregate device) | working (used by meters/spectrum) |
| Route model + persistence | `SourceRoute.swift`, `RouteStore.swift` (lock-free snapshot, audio-thread reads, main-actor writes) | working |
| Replay to chosen device | `AudioRouter.swift` (one `AVAudioEngine` per output device, pinned via `kAudioOutputUnitProperty_CurrentDevice`) | implemented, **not currently fed correct samples** |
| Per-source UI picker | `SourceRouteMenu` in `main.swift` | working |
| Device discovery | `OutputDeviceMonitor.swift` | working |

What is missing is (1) exclusive capture — today the tap only *observes*;
(2) a correct sample path into the router; (3) a tap lifecycle that can
change mute behavior at runtime; (4) tests for the routing layer.

## 1. Exclusive capture via `CATapMuteBehavior`

From `CATapDescription.h` (verified against the macOS 27 SDK):

| Behavior | Hardware path | Tap data |
| --- | --- | --- |
| `CATapUnmuted` (today) | plays normally | captured |
| `CATapMuted` | **never** plays | captured |
| `CATapMutedWhenTapped` | plays **until a client reads the tap**; muted for the duration of read activity | captured |

`CATapMutedWhenTapped` is the mechanism that makes split routing work with
no virtual audio driver and no echo:

- While `AudioRouter` is consuming the tap (i.e. the source has an enabled
  route and its engine is running), Core Audio suppresses the original
  playback → source is heard **only** on the routed device.
- If the router dies or the route is disabled, the hardware path resumes on
  its own → graceful fallback to normal macOS behavior. Strictly better
  than `CATapMuted`, which would leave the source silent if our engine
  failed.

**Decision:** taps for routed sources use `.mutedWhenTapped`; taps that
only feed meters/spectrum keep `.unmuted`. No BackgroundMusic / BlackHole /
HAL plugin required.

Echo is therefore impossible *while consumption is healthy*. The remaining
risk is the gap between "route enabled" and "engine actually reading" —
covered by the lifecycle rules in §4.

## 2. Sample-path correctness fixes (required regardless)

`ApplicationAudioMonitor.startTap` currently gates **both** paths behind a
30 Hz visualization throttle, and misreports format:

```swift
guard shouldForward else { return }          // 30 fps gate — must not gate the router
...
AudioRouter.shared.handleSamples(
    fromSourceObjectID: sourceID,
    bundleIdentifier: bundleID,
    bufferList: bufferList,
    frameCount: samples.count,               // BUG: float count, not frame count
    sampleRate: 48_000                       // BUG: hardcoded; use tap.sampleRate
)
```

Changes:

1. Forward to `AudioRouter` **unconditionally, before** the throttle guard;
   the throttle continues to gate only the spectrum/waveform path. The
   router's own guard (`isRoutingEnabled` + route lookup) already makes the
   no-route case near-free.
2. Derive frame count from the buffer list
   (`mDataByteSize / sizeof(Float32) / channelCount`), not from the copied
   float array.
3. Pass the tap's real nominal sample rate (already read into
   `ProcessAudioTap.sampleRate`) instead of the hardcoded 48 kHz.
4. Channel count: stop inferring it from sample-count parity in
   `AudioRouter.inferInputChannelCount`. `CATapDescription` stereo mixdown
   is stereo by construction — plumb the real channel count through the
   handler signature.

## 3. Latency budget

Replay through `AVAudioEngine` adds one aggregate-buffer of delay. Current
`ProcessAudioTap` sets 4,096 frames @ 48 kHz ≈ **85 ms** — chosen to avoid
HALC overload with many concurrent taps. For listening this is acceptable;
for lip-sync-critical video it is noticeable.

Plan: keep 4,096 for the first cut. Follow-up knob: per-tap buffer size
(1,024 frames ≈ 21 ms) applied only to taps of *routed* sources, with the
overload risk re-tested. The visualization taps keep the conservative size.

## 4. Tap lifecycle state machine

`muteBehavior` is baked into `CATapDescription` at creation, so changing a
source's routing requires recreating its tap. `ApplicationAudioMonitor`
gains a small per-source lifecycle:

```
observeOnly  ──(user enables route)──▶ routed
routed       ──(user disables / "System default")──▶ observeOnly
routed       ──(target device vanishes)──▶ observeOnly (+ UI notice)
```

- Transition = stop + recreate tap with the new `muteBehavior`. Keep the
  recreate fast and off the critical path; meters may blank for one frame.
- Debounce rapid toggles (e.g. 250 ms) so menu clicks don't thrash the
  HAL.
- On process exit: macOS 26's `CATapDescription.processRestoreEnabled`
  re-attaches the tap when the process returns. Enable it and verify
  behavior on 26.6; keep the existing object-ID-recovery path
  (`RouteStore.route(forBundleIdentifier:)`) as the pre-26 fallback.
- Bluetooth (AirPods) sample-rate renegotiation on connect/disconnect:
  `OutputEngine` must be torn down and rebuilt when the target device's
  format changes; subscribe to `kAudioDevicePropertyNominalSampleRate`
  notifications on routed target devices.

## 5. Edge cases

- **Target device disappears** (AirPods case closes): drop the engine,
  flip the source to `observeOnly`, surface a transient banner (the nook
  already has `NookTransientStatusBanner`). Never leave a source muted
  with no consumer — the `mutedWhenTapped` semantics make the fallback
  automatic, but the UI must still announce it.
- **Route points at device that becomes the system default**: harmless
  (still exclusive), but the UI should show it as "System" to avoid
  confusion.
- **Many routed sources**: each routed source is its own aggregate device
  + engine. Watch the HALC overload note in `ProcessAudioTap`; if more
  than ~4 concurrent routed taps skip cycles, revisit buffer sizing
  before anything else.
- **Permissions**: process taps require no per-app TCC prompt beyond what
  the app already holds (audio capture usage string exists). Verify the
  `.mutedWhenTapped` path needs nothing extra.
- **App sandbox**: taps + aggregate devices work under the app sandbox
  today (meters prove it). Re-verify with muting enabled.

## 6. Testing strategy

`RouteStore` / `SourceRoute` are pure logic living in the app target,
which has no test target. Move them into the `Nook` package (new target or
existing `NookKit`) so they can be tested with the existing harness
(Alec's test-first flow: feature branch → dev → main).

Test list (write first, before the fix):

1. `RouteStore` — upsert preserves existing `outputDeviceID` on bundle-ID
   collision; `setOutput`/`setEnabled` update only the targeted route;
   snapshot visibility from a non-main thread; persistence round-trip.
2. `RouteStore` — `isRoutingEnabled` false ⇒ route lookups irrelevant
   (router no-op contract).
3. Tap lifecycle — transition matrix `observeOnly ⇄ routed`, including
   debounce (transitions collapse into one recreate).
4. Frame-count derivation — interleaved stereo bufferList → frame count;
   mono; empty buffer.
5. Router scheduling — buffer lands on the correct engine's queue, keyed
   by `(bundleID, deviceID)`; no allocation on the audio thread beyond the
   copy (assert by review, not test).

Items 3–5 need the audio seam refactored to be injectable
(`ProcessAudioTap` behind a protocol; fake IOProc driver like
`FakeNookSurface` does for surfaces).

## 7. Phased plan

| Phase | Deliverable | Acceptance |
| --- | --- | --- |
| 0 | Tests above, failing where behavior is missing | red |
| 1 | Sample-path fixes (§2) — replay continuous and sample-accurate, still `.unmuted` | AirPods route hears audio *plus* echo (expected) |
| 2 | Mute behavior + lifecycle (§1, §4) | routed source audible **only** on target; disabling route restores normal playback without app restart |
| 3 | Edge cases (§5) + latency knob | device-unplug banner; no skips with 2 routed sources for 30 min |
| 4 | Polish: per-source buffer size, settings copy | — |

Phase 1 alone is shippable and low-risk; phase 2 is the first commit that
can surprise (muting real playback), so it lands behind the existing
"Per-source routing" toggle which stays default-off.

## 8. Resolved questions

1. **Latency** — audio-focus only; 85 ms acceptable to start (decision 1).
2. **Picker placement** — stays in the compact row; tapping it expands
   the panel and the picker renders in the expanded layout (decision 2).
3. **macOS 26 only** — adopt `processRestoreEnabled` and 26-era tap APIs;
   no pre-26 fallbacks in the app (decision 3).
