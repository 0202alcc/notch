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
    /// Vocal isolation: center-channel content in the band above the
    /// crossover, with the original stereo low end preserved (kick and
    /// bass stay full and wide). This is classic mid/side extraction,
    /// not AI stem separation: center-panned instruments in the vocal
    /// band remain; mono content is unaffected.
    case vocals
    /// Instrumental isolation: the classic karaoke cancellation applied
    /// above the crossover (side channel only - center content
    /// cancels), with the original stereo low end preserved so kick and
    /// bass survive.
    case instrumental
}

/// Mid/side focus processing for one routed source's replay samples.
///
/// Band-aware design with a two-stage (12 dB/oct) crossover at 300 Hz:
/// below the crossover the original stereo signal passes untouched
/// (as the exact complement of the extracted high band - no dip at the
/// crossover); above it, vocal mode keeps the center (mid) and
/// instrumental mode keeps the sides (L-R). The lowpass states persist
/// across buffers so mode switches and buffer boundaries are
/// click-free.
public struct StereoFocusProcessor: Sendable {
    public var mode: SourceFocusMode = .full

    // Two-stage lowpass states (12 dB/oct) for each split path.
    private var lpL1: Float = 0
    private var lpL2: Float = 0
    private var lpR1: Float = 0
    private var lpR2: Float = 0
    private var lpMid1: Float = 0
    private var lpMid2: Float = 0
    private var lpSide1: Float = 0
    private var lpSide2: Float = 0

    /// The crossover between "original stereo" and "processed" bands.
    private let crossoverHz: Double = 300

    public init(sampleRate: Double) {}

    public mutating func reset() {
        lpL1 = 0
        lpL2 = 0
        lpR1 = 0
        lpR2 = 0
        lpMid1 = 0
        lpMid2 = 0
        lpSide1 = 0
        lpSide2 = 0
    }

    /// Processes planar channel samples in place.
    public mutating func process(
        _ channels: inout [[Float]],
        sampleRate: Double
    ) {
        // The split filters advance regardless of mode (cheap) so
        // re-entering a focus mode later starts from warm state.
        guard channels.count >= 2, !channels[0].isEmpty else { return }

        let alpha = Float(
            1 - exp(-2 * Double.pi * crossoverHz / sampleRate)
        )

        let frameCount = channels[0].count
        let stereo = channels.count >= 2

        for index in 0..<frameCount {
            var left = channels[0][index]
            var right = stereo ? channels[1][index] : left

            // Two-stage lowpass states advance regardless of mode.
            lpL1 += alpha * (left - lpL1)
            lpL2 += alpha * (lpL1 - lpL2)
            lpR1 += alpha * (right - lpR1)
            lpR2 += alpha * (lpR1 - lpR2)

            guard stereo, mode != .full else {
                channels[0][index] = left
                channels[1][index] = right
                continue
            }

            let mid = (left + right) / 2
            let side = (left - right) / 2
            lpMid1 += alpha * (mid - lpMid1)
            lpMid2 += alpha * (lpMid1 - lpMid2)
            lpSide1 += alpha * (side - lpSide1)
            lpSide2 += alpha * (lpSide1 - lpSide2)

            // Low bands = the 2-stage lowpass outputs; the high bands
            // are their exact complements (x - low) - no crossover dip.
            let lowL = lpL2
            let lowR = lpR2
            let highMid = mid - lpMid2
            let highSide = side - lpSide2

            switch mode {
            case .full:
                break
            case .vocals:
                // Low band: original stereo. Vocal band and up: center
                // only.
                left = lowL + highMid
                right = lowR + highMid
            case .instrumental:
                // Low band: original stereo. Vocal band and up: sides
                // only (center cancels).
                left = lowL + highSide
                right = lowR - highSide
            }

            channels[0][index] = left
            channels[1][index] = right

            for c in 2..<channels.count {
                channels[c][index] = (left + right) / 2
            }
        }
    }
}
