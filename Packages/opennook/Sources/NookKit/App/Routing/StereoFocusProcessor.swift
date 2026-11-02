//
//  StereoFocusProcessor.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// Focus mode for a routed source's replay.
public enum SourceFocusMode: Equatable, Sendable {
    /// Full stereo - no processing.
    case full
    /// Vocal isolation: center-channel (mid) only. Works because vocals
    /// are typically center-panned; center-panned instruments (kick,
    /// bass, snare) remain - this is classic mid/side extraction, not
    /// AI stem separation.
    case vocals
    /// Instrumental isolation: side channel only (the classic karaoke
    /// cancellation, L-R), with the low end restored via a lowpass on
    /// the mid channel so kick/bass survive.
    case instrumental
}

/// Mid/side focus processing for one routed source's replay samples.
///
/// Stateful: the bass-restore lowpass carries filter history across
/// buffers (no clicks on mode switches or buffer boundaries). Pure
/// sample math - fully testable without the audio engine.
public struct StereoFocusProcessor: Sendable {
    public var mode: SourceFocusMode = .full

    /// Bass-restore lowpass state (two cascaded one-pole stages).
    private var lpStage1: Float = 0
    private var lpStage2: Float = 0

    private let bassRestoreCutoffHz: Double = 200

    public init(sampleRate: Double) {}

    public mutating func reset() {
        lpStage1 = 0
        lpStage2 = 0
    }

    /// Processes planar channel samples in place.
    public mutating func process(
        _ channels: inout [[Float]],
        sampleRate: Double
    ) {
        switch (mode, channels.count) {
        case (.full, _), (_, 0), (_, 1):
            return
        case (.vocals, 2...):
            for index in 0..<channels[0].count {
                var mid: Float = 0
                for channel in channels {
                    mid += channel[index]
                }
                mid /= Float(channels.count)
                for c in channels.indices {
                    channels[c][index] = mid
                }
            }
        case (.instrumental, let channelCount) where channelCount >= 2:
            let alpha = Float(1 - exp(-2 * Double.pi * bassRestoreCutoffHz / sampleRate))
            for index in 0..<channels[0].count {
                let mid = (channels[0][index] + channels[1][index]) / 2
                let side = (channels[0][index] - channels[1][index]) / 2

                // Two-pole cascade: keeps the karaoke cancellation clean
                // above the cutoff while passing kick/bass below it.
                lpStage1 += alpha * (mid - lpStage1)
                lpStage2 += alpha * (lpStage1 - lpStage2)

                let left = side + lpStage2
                let right = -side + lpStage2
                channels[0][index] = left
                channels[1][index] = right

                // Extra channels (>2): carry the bass-restored mono.
                for c in 2..<channelCount {
                    channels[c][index] = lpStage2
                }
            }
        default:
            return
        }
    }
}
