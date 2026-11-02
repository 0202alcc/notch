//
//  EQBand.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// The three-band per-source equalizer: lows / mids / highs.
///
/// Bands map onto `AVAudioUnitEQ` filter parameters in the replay
/// engine: a low-shelf for bass, a parametric peak for mids, a
/// high-shelf for treble. Gain range is -12...+12 dB per band; 0 dB is
/// flat.
public enum EQBand: String, CaseIterable, Codable, Sendable {
    case low
    case mid
    case high

    /// Center/corner frequency in Hz.
    public var frequencyHzValue: Double {
        switch self {
        case .low: return 150
        case .mid: return 1_000
        case .high: return 6_000
        }
    }

    /// Center/corner frequency in Hz (AVAudioUnitEQ uses Float).
    public var frequencyHz: Float {
        Float(frequencyHzValue)
    }

    /// Compact frequency label for the knob (kHz-compressed).
    public var label: String {
        let hz = Int(frequencyHz)
        return hz >= 1000 ? "\(hz / 1000)kHz" : "\(hz)Hz"
    }

    /// The knob's gain range.
    public static let minDB: Double = -12
    public static let maxDB: Double = 12

    public static func clampDB(_ db: Double) -> Double {
        min(max(db, minDB), maxDB)
    }

    /// Knob position (0...1) to gain: linear, 0.5 = flat.
    public static func db(forKnobPosition position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        return minDB + clamped * (maxDB - minDB)
    }

    /// Gain to knob position (0...1).
    public static func knobPosition(forDB db: Double) -> Double {
        let clamped = clampDB(db)
        return (clamped - minDB) / (maxDB - minDB)
    }
}
