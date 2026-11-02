# HTDemucs probe scripts

Standalone probes for the vocal-isolation feasibility study (November
2026 session). Run order tells the story:

| Script | What it established |
| --- | --- |
| `htdemucs_probe.swift` | Synthetic-input smoke test. Cold inference 14.9s (one-time graph compile), **warm 0.3s for 10s of audio (RTF 0.03)**. Pure-sine input is out-of-domain for the model - everything landed in "other". |
| `htdemucs_live_probe.swift` | Live capture via a CoreAudio process tap + separation of REAL Spotify audio. Found: the "vocals" stem was silent without input normalization (rms 0.0001 → 0.0156 after peak-normalizing the input) - the CoreML conversion dropped the official Demucs normalization wrapper. |
| `htdemucs_v2_probe.swift` | Quality pipeline v1: AVAudioConverter resample (linear interpolation aliased badly), demucs-style mean/std normalization, chunked overlap-add. Still flawed: the OLA window was a full triangle (zero at both segment edges). |
| `htdemucs_v3_probe.swift` | The corrected pipeline: 2.5s overlap (official default), correct edge-fade OLA window (1.0 across the segment, fades only over the overlap regions), 2-shift averaging, **instrumental computed as the residual (mix − vocals)** so vocals+instrumental == mix exactly (residual rms 0.000000). FP16 vs FP32 A/B: FP16 1.37s/12s (RTF 0.11), FP32 7.36s/12s (RTF 0.61). |

## Model sources

- `dexxdean/htdemucs-coreml` (Hugging Face) - FP16 + FP32, 10s
  segments, `.cpuAndGPU` (ANE unstable). Cached under
  `~/Library/Caches/AlecsNookModels/`.
- Alternatives: `mlboydaisuke/HTDemucs-CoreML` (75 MB, cpuOnly),
  `pkurzok/htdemucs-coreml` (unpacked for incremental download).

## Verdict at checkpoint

Speed: emphatically viable (RTF ≤ 0.11 warm). Quality: better with the
proper pipeline but the vocal stem still carries accompaniment -
below the bar the user set (Serato Stems). Next levers documented in
`docs/vocal-isolation-research.md`.
