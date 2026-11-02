# Vocal Isolation Research

Goal: true vocal / instrumental isolation on the replay path, behind
the nook's isolation buttons. Companion to `research/htdemucs/`.

## What's shipped today

Mid/side "focus" processing (`StereoFocusProcessor`, NookKit, 9
tests): band-aware center/side extraction with a two-stage 300 Hz
crossover. Honest limits: spatial separation only - center-panned
instruments stay in vocal mode. It is a "vocal emphasis" tool; the
user judged real isolation quality insufficient.

## The ML path: HTDemucs via CoreML (probed, November 2026)

**Speed verdict: emphatically viable.**

| Configuration | RTF (lower = better) |
| --- | --- |
| FP16, warm, 10s segment | **0.03** |
| FP16, v3 pipeline (2.5s overlap OLA + 2 shifts, 12s) | 0.11 |
| FP32, same pipeline | 0.61 |

Cold-start graph compilation is one-time (~15s). Live streaming
separation is feasible on this machine with the FP16 model and large
headroom.

**Quality findings:**

1. The CoreML conversions are **stateless** - the official Demucs
   normalization wrapper is NOT baked in. Inference on un-normalized
   input produced a silent "vocals" stem (rms 0.0001). Demucs-style
   mean/std normalization (mono ref = (L+R)/2, stats over time) is
   REQUIRED.
2. The overlap-add window must be **1.0 across the segment with fades
   only over the overlap regions**. A full triangle (zero at both
   segment edges) starves the overlap of weight and amplifies seam
   artifacts - this was the v2 quality bug.
3. **Conservation by construction**: compute the instrumental as the
   residual (mix − vocals). Guarantees vocals+instrumental == mix
   exactly (measured residual 0.000000) - matches the user's stated
   requirement ("both enabled = hear the song normally").
4. Even with the correct pipeline, the FP16 vocal stem still carries
   accompaniment - the user's verdict: better, but short of Serato
   Stems quality. The htdemucs FP16 conversion appears to be the
   ceiling reached so far.

## Next levers (in order of expected gain)

1. **FP32 A/B** - model downloaded (`HTDemucs_CoreML.mlpackage`,
   410 MB); RTF 0.61 still under real-time. Judge whether the
   numerics close the gap.
2. **Stronger vocal models**: MDX23C / BS-Roformer-class models beat
   htdemucs on vocal separation (the UVR ecosystem's gold standard).
   Check Hugging Face for CoreML conversions; if none exist, conversion
   via `coremltools` from the ONNX checkpoints is the path (the
   dexxdean repo's `convert.py` documents the three HTDemucs
   conversion blockers - STFT/ISTFT, attention decomposition,
   scatter_add - most apply to any audio model).
3. **Official-demucs-faithful inference**: multiple random-shift
   segment averaging (demucs `shifts` parameter), longer overlap -
   both cheap now that RTF has headroom.
4. **Architecture for streaming** (design sketch, pending quality
   sign-off): capture-tap chunks (~10s windows, 2.5s hop) → inference
   on a background GPU queue → crossfaded stem replay with ~2.5-3s
   delay when a focus mode is active; instant revert to live tap audio
   when the user toggles off. RTF ≤ 0.11 leaves ample headroom even
   with overlap+shifts.

## Open items

- Which stem order the FP16 package really emits (documented
  [vocals, drums, bass, other]; energy distributions suggested
  otherwise in one capture - listen-test the four stems).
- Battery/thermal impact of continuous GPU inference (~10% duty cycle
  at RTF 0.11) - measure in a long session.
- Where the model lives in a deployed app (bundle = +200 MB install;
  cache-download on first use is the better shape).
