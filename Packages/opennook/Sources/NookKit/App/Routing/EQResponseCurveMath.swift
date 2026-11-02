//
//  EQResponseCurveMath.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// Pure math for rendering the live EQ frequency-response curve shown
/// above the nook's potentiometers.
///
/// Implements the RBJ audio-EQ-cookbook biquad magnitude response -
/// the same coefficient family `AVAudioUnitEQ` implements - for one
/// low shelf, one parametric bell, and one high shelf, evaluated at
/// log-spaced frequencies across the audible range.
public enum EQResponseCurveMath {
    public static let sampleCount = 96
    public static let minFrequencyHz = 20.0
    public static let maxFrequencyHz = 20000.0
    /// The engine's IO sample rate for coefficient computation.
    private static let sampleRate = 48000.0

    /// The combined (sum) response in dB at `sampleCount` log-spaced
    /// frequencies from 20 Hz to 20 kHz.
    public static func combinedResponseDB(
        low: Double, mid: Double, high: Double
    ) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let f = pow(10, log10(minFrequencyHz) + t * (log10(maxFrequencyHz) - log10(minFrequencyHz)))
            result.append(
                responseDB(band: .low, db: low, frequencyHz: f)
                    + responseDB(band: .mid, db: mid, frequencyHz: f)
                    + responseDB(band: .high, db: high, frequencyHz: f)
            )
        }
        return result
    }

    /// One band's magnitude response in dB at a frequency.
    public static func responseDB(
        band: EQBand, db: Double, frequencyHz f: Double
    ) -> Double {
        let coeffs = biquad(band: band, db: db, f0: band.frequencyHzValue)
        let w = 2 * Double.pi * f / sampleRate
        let c1 = cos(w)
        let s1 = sin(w)
        let c2 = cos(2 * w)
        let s2 = sin(2 * w)

        let numRe = coeffs.b0 + coeffs.b1 * c1 + coeffs.b2 * c2
        let numIm = -coeffs.b1 * s1 - coeffs.b2 * s2
        let denRe = coeffs.a0 + coeffs.a1 * c1 + coeffs.a2 * c2
        let denIm = -coeffs.a1 * s1 - coeffs.a2 * s2

        let magnitude = sqrt(numRe * numRe + numIm * numIm)
            / max(sqrt(denRe * denRe + denIm * denIm), 1e-9)
        return 20 * log10(max(magnitude, 1e-6))
    }

    // MARK: - Western note names (A440 equal temperament)

    public struct NoteMarker: Equatable, Sendable {
        public let frequencyHz: Double
        public let name: String
    }

    private static let pitchNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// Nearest Western note name for a frequency (A440, equal
    /// temperament): MIDI = 69 + 12·log2(f/440).
    public static func noteName(forHz f: Double) -> String {
        let midi = Int((69 + 12 * log2(f / 440)).rounded())
        let pitch = pitchNames[((midi % 12) + 12) % 12]
        let octave = midi / 12 - 1
        return "\(pitch)\(octave)"
    }

    /// Axis markers: every A octave inside the curve's frequency
    /// window (A0 27.5 Hz ... A8 7040 Hz).
    public static func octaveMarkers() -> [NoteMarker] {
        var markers: [NoteMarker] = []
        for octave in 0...10 {
            let f = 27.5 * pow(2, Double(octave)) // A0 = 27.5 Hz
            guard f >= minFrequencyHz, f <= maxFrequencyHz else { continue }
            markers.append(
                NoteMarker(frequencyHz: f, name: "A\(octave)")
            )
        }
        return markers
    }

    // MARK: - RBJ cookbook coefficients

    private struct Biquad {
        var b0: Double, b1: Double, b2: Double
        var a0: Double, a1: Double, a2: Double
    }

    private static func biquad(
        band: EQBand, db: Double, f0: Double
    ) -> Biquad {
        // A = 10^(dB/40) gives the symmetric boost/cut the EQ gain
        // semantics expect.
        let A = pow(10, db / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = cos(w0)
        let sw = sin(w0)
        let sqrtA = sqrt(A)

        switch band {
        case .low:
            let alpha = (sw / 2) * sqrt((A + 1 / A) * 0 + 2) // shelf slope S=1
            return Biquad(
                b0: A * (A + 1 - (A - 1) * cw + 2 * sqrtA * alpha),
                b1: 2 * A * (A - 1 - (A + 1) * cw),
                b2: A * (A + 1 - (A - 1) * cw - 2 * sqrtA * alpha),
                a0: A + 1 + (A - 1) * cw + 2 * sqrtA * alpha,
                a1: -2 * (A - 1 + (A + 1) * cw),
                a2: A + 1 + (A - 1) * cw - 2 * sqrtA * alpha
            )
        case .high:
            let alpha = (sw / 2) * sqrt((A + 1 / A) * 0 + 2)
            return Biquad(
                b0: A * (A + 1 + (A - 1) * cw + 2 * sqrtA * alpha),
                b1: -2 * A * (A - 1 + (A + 1) * cw),
                b2: A * (A + 1 + (A - 1) * cw - 2 * sqrtA * alpha),
                a0: A + 1 - (A - 1) * cw + 2 * sqrtA * alpha,
                a1: 2 * (A - 1 - (A + 1) * cw),
                a2: A + 1 - (A - 1) * cw - 2 * sqrtA * alpha
            )
        case .mid:
            // Parametric bell; Q from the ~1.2-octave bandwidth.
            let q = 1.17
            let alpha = sw / (2 * q)
            return Biquad(
                b0: 1 + alpha * A,
                b1: -2 * cw,
                b2: 1 - alpha * A,
                a0: 1 + alpha / A,
                a1: -2 * cw,
                a2: 1 - alpha / A
            )
        }
    }
}
