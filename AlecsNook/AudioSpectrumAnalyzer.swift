//
//  AudioSpectrumAnalyzer.swift
//  AlecsNook
//
//  Computes a short-time Fourier transform of a buffer of audio samples and
//  reduces the result to a small number of log-spaced magnitude bins suitable
//  for a compact visualizer.
//
//  Built on Accelerate's vDSP so each frame is a few hundred microseconds on
//  modern Macs and the analyzer can comfortably run every time the tap
//  delivers a buffer (~10-40 Hz visual update rate).
//

import Accelerate
import Foundation

final class AudioSpectrumAnalyzer {
    let windowSize: Int
    let binCount: Int

    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length
    private let halfSize: Int
    private let uniqueBinCount: Int
    private let window: [Float]

    // Persistent state for attack/release smoothing. Kept across frames so
    // bars spring up quickly when audio hits and decay gracefully when it
    // stops.
    private var smoothed: [Float]

    /// Per-bin attack/release coefficients. Attack is fast (bars pop up),
    /// release is slower (bars decay gently).
    private let attack: Float = 0.6
    private let release: Float = 0.18

    /// dB range mapped onto 0...1 for the visualizer. Music typically
    /// sits between -50 dB and -10 dB per FFT bin, so this window keeps
    /// quiet signals visible while leaving headroom for transients.
    private let dbFloor: Float = -60
    private let dbCeil: Float = 0

    /// Scaling factor applied to squared FFT magnitudes so the output
    /// represents signal amplitude (not raw transform coefficients).
    /// `vDSP_fft_zrip`'s forward transform does not normalize by N, so
    /// the squared magnitudes come out scaled by N^2. We divide by
    /// `(N/2)^2 * windowCoherentGain^2` so a full-scale sine wave
    /// through the Hann window maps to amplitude^2 = 1 (i.e. 0 dB).
    private let magnitudeNormalizer: Float

    init(windowSize: Int = 1024, binCount: Int = 10) {
        precondition(windowSize > 0 && (windowSize & (windowSize - 1)) == 0,
                     "windowSize must be a power of two")
        precondition(binCount > 0)

        self.windowSize = windowSize
        self.binCount = binCount
        self.halfSize = windowSize / 2
        self.uniqueBinCount = halfSize / 2
        self.log2n = vDSP_Length(log2(Float(windowSize)))

        guard let setup = vDSP_create_fftsetup(
            log2n,
            FFTRadix(kFFTRadix2)
        ) else {
            fatalError("vDSP_create_fftsetup failed for N=\(windowSize)")
        }
        self.fftSetup = setup

        var hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(
            &hann,
            vDSP_Length(windowSize),
            Int32(vDSP_HANN_NORM)
        )
        self.window = hann

        // Hann window coherent gain: sum(window)/N ≈ 0.5. Combined with
        // the FFT's missing 1/N factor, the squared magnitudes need to
        // be divided by (N/2)^2 * 0.5^2 to recover amplitude.
        let windowCoherentGain: Float = 0.5
        self.magnitudeNormalizer =
            4.0 / (Float(windowSize * windowSize) * windowCoherentGain * windowCoherentGain)

        self.smoothed = [Float](repeating: 0, count: binCount)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Analyzes the supplied samples and returns `binCount` smoothed
    /// magnitudes normalized to `0...1`.
    ///
    /// - Parameters:
    ///   - samples: Mono (or multi-channel - channels are averaged) PCM in
    ///     linear amplitude, `Float`, in roughly `-1...1`.
    ///   - sampleRate: Sample rate of `samples` in Hz. Used to choose the
    ///     FFT bin range each output bin covers (log-spaced).
    func analyze(samples: [Float], sampleRate: Float) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else {
            return smoothed
        }

        let count = min(windowSize, samples.count)
        let mono = monoMix(samples: samples, frameCount: count)

        // Window the signal in place.
        var windowed = [Float](repeating: 0, count: windowSize)
        mono.withUnsafeBufferPointer { src in
            vDSP_vmul(
                src.baseAddress!,
                1,
                window,
                1,
                &windowed,
                1,
                vDSP_Length(windowSize)
            )
        }

        // Run the real-to-complex FFT in place. `vDSP_fft_zrip` expects
        // the input as a `DSPSplitComplex` with the real samples packed
        // even/odd (which `vDSP_ctoz` produces from a regular Float
        // array). The output lives in the same split: bin 0 (DC) at
        // realp[0], bins 1..N/4-1 at realp/imagp pairs, Nyquist at
        // realp[N/4], and the negative-frequency mirrored copies at
        // realp/imagp indices N/4+1..N/2-1.
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                windowed.withUnsafeMutableBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfSize
                    ) { complexPtr in
                        vDSP_ctoz(
                            complexPtr,
                            2,
                            &split,
                            1,
                            vDSP_Length(halfSize)
                        )
                    }
                }

                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    log2n,
                    FFTDirection(FFT_FORWARD)
                )

                vDSP_zvmags(
                    &split,
                    1,
                    &magnitudes,
                    1,
                    vDSP_Length(halfSize)
                )
            }
        }

        // Convert squared magnitudes to dB. First normalize by N^2 (Hann
        // window coherent gain compensated) so a full-scale sine wave
        // through the window maps to amplitude^2 = 1 (0 dB), then floor
        // at a small positive value so silent bins don't go to
        // -infinity.
        var decibels = [Float](repeating: 0, count: halfSize)
        let floor: Float = 1e-7
        for index in 0..<halfSize {
            let value = magnitudes[index] * magnitudeNormalizer + floor
            decibels[index] = 10 * log10(value)
        }

        // Map each of our `binCount` output bins to a log-spaced range of
        // the unique FFT bins (skipping DC at index 0 and the mirrored
        // duplicates from index uniqueBinCount onwards).
        let nyquist = sampleRate / 2
        let minHz: Float = 60
        let maxHz = nyquist
        let logMin = log10(minHz)
        let logMax = log10(maxHz)

        var output = [Float](repeating: 0, count: binCount)

        for bin in 0..<binCount {
            let loHz = powf(
                10,
                logMin + (Float(bin) / Float(binCount)) * (logMax - logMin)
            )
            let hiHz = powf(
                10,
                logMin + (Float(bin + 1) / Float(binCount)) * (logMax - logMin)
            )

            let loBin = max(
                1,
                Int(floorf((loHz / nyquist) * Float(uniqueBinCount)))
            )
            let hiBin = min(
                uniqueBinCount,
                Int(ceilf((hiHz / nyquist) * Float(uniqueBinCount)))
            )

            guard hiBin >= loBin else { continue }

            var sum: Float = 0
            for index in loBin...hiBin {
                sum += decibels[index]
            }
            let avgDb = sum / Float(hiBin - loBin + 1)

            let normalized = (avgDb - dbFloor) / (dbCeil - dbFloor)
            let clamped = min(max(normalized, 0), 1)

            let previous = smoothed[bin]
            if clamped > previous {
                output[bin] = previous + (clamped - previous) * attack
            } else {
                output[bin] = previous + (clamped - previous) * release
            }
        }

        smoothed = output
        return output
    }

    /// Reduces a buffer of samples to mono by averaging every channel in
    /// `frameCount`-sized blocks. Expects `samples.count` to be a multiple
    /// of `frameCount` (channels laid out back-to-back), which is how
    /// non-interleaved Float32 buffers are laid out in an `AudioBufferList`.
    private func monoMix(
        samples: [Float],
        frameCount: Int
    ) -> [Float] {
        guard samples.count >= frameCount else {
            return samples
        }

        let channelCount = samples.count / frameCount
        if channelCount <= 1 {
            return Array(samples.suffix(frameCount))
        }

        var mono = [Float](repeating: 0, count: frameCount)

        samples.withUnsafeBufferPointer { src in
            for channel in 0..<channelCount {
                let channelBase = src.baseAddress!.advanced(
                    by: channel * frameCount
                )
                vDSP_vadd(
                    mono,
                    1,
                    channelBase,
                    1,
                    &mono,
                    1,
                    vDSP_Length(frameCount)
                )
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(
                mono,
                1,
                &divisor,
                &mono,
                1,
                vDSP_Length(frameCount)
            )
        }

        return mono
    }
}