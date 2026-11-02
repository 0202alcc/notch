//
//  StereoFocusProcessorTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for the mid/side focus processor (vocal / instrumental
/// isolation buttons).
///
/// The math: mid = (L+R)/2 (center-panned content, where vocals live),
/// side = (L-R)/2 (stereo-width content). "Instrumental" additionally
/// restores the low end (kick/bass are center-panned) via a one-pole
/// lowpass on the mid channel.
final class StereoFocusProcessorTests: XCTestCase {
    private let fs: Double = 48_000

    private func stereo(_ l: [Float], _ r: [Float]) -> [[Float]] {
        [l, r]
    }

    // MARK: - Full passthrough

    func testFullModeIsExactPassthrough() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        var channels = stereo([0.1, -0.2, 0.3], [0.4, 0.5, -0.6])
        let original = channels

        processor.process(&channels, sampleRate: fs)

        XCTAssertEqual(channels, original)
    }

    // MARK: - Vocal isolation (mid)

    func testVocalsCollapseToCenterMono() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        var channels = stereo([1.0, 1.0, 1.0], [-1.0, 1.0, -1.0])
        processor.process(&channels, sampleRate: fs)

        // mid = (L+R)/2: [0, 1, 0] - both output channels carry it.
        XCTAssertEqual(channels[0], [0, 1, 0])
        XCTAssertEqual(channels[1], [0, 1, 0])
    }

    /// A mono (L==R) signal is unchanged in vocal mode - the center IS
    /// the whole signal.
    func testVocalsLeavesMonoContentIntact() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        var channels = stereo([0.3, 0.7, -0.5], [0.3, 0.7, -0.5])
        processor.process(&channels, sampleRate: fs)

        XCTAssertEqual(channels[0], [0.3, 0.7, -0.5])
        XCTAssertEqual(channels[1], [0.3, 0.7, -0.5])
    }

    // MARK: - Instrumental isolation (side)

    /// Hard-panned content (pure side) survives instrumental mode.
    func testInstrumentalKeepsHardPannedContent() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        // Pure side: L = +x, R = -x.
        var channels = stereo([1.0, 1.0], [-1.0, -1.0])
        processor.process(&channels, sampleRate: fs)

        // side = (L-R)/2 = 1.0; out_L = +side, out_R = -side.
        XCTAssertEqual(channels[0], [1.0, 1.0])
        XCTAssertEqual(channels[1], [-1.0, -1.0])
    }

    /// Center content (L == R) cancels in instrumental mode... except
    /// the low end, which is restored so kick/bass survive the karaoke
    /// cancellation.
    func testInstrumentalCancelsCenterHighsButRestoresBass() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        // A center tone at 2 kHz (well above the bass-restore lowpass):
        // must cancel to ~0.
        let n = 512
        let highTone = (0..<n).map { i -> Float in
            sin(Float(2 * .pi * 2000 * Double(i) / fs))
        }
        var channels = stereo(highTone, highTone)
        processor.process(&channels, sampleRate: fs)

        let peak = channels[0].map { abs($0) }.max() ?? 1
        XCTAssertLessThan(peak, 0.05, "2 kHz center content must cancel")

        // A center tone at 40 Hz (below the restore lowpass): must
        // survive the bass restore.
        let bassTone = (0..<n).map { i -> Float in
            sin(Float(2 * .pi * 40 * Double(i) / fs))
        }
        var bassChannels = stereo(bassTone, bassTone)
        processor.process(&bassChannels, sampleRate: fs)

        let bassPeak = bassChannels[0].suffix(256).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(bassPeak, 0.3, "40 Hz center content must survive")
    }

    // MARK: - Mode switching mid-stream

    /// The lowpass state persists across buffers (no clicks when
    /// switching modes mid-song).
    func testProcessorStatePersistsAcrossCalls() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        let tone = (0..<512).map { i -> Float in
            sin(Float(2 * .pi * 40 * Double(i) / fs))
        }
        var first = stereo(tone, tone)
        processor.process(&first, sampleRate: fs)
        let firstTail = first[0].suffix(64).map { abs($0) }.max() ?? 0

        var second = stereo(tone, tone)
        processor.process(&second, sampleRate: fs)
        let secondTail = second[0].suffix(64).map { abs($0) }.max() ?? 0

        // The second buffer's tail should be at least as strong (the
        // lowpass state carried over rather than restarting cold).
        XCTAssertGreaterThanOrEqual(secondTail, firstTail * 0.9)
    }

    // MARK: - Mono input edge case

    /// A single-channel source has no stereo image - focus modes pass
    /// it through unchanged rather than mangling it.
    func testMonoInputPassesThrough() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        var channels: [[Float]] = [[0.2, 0.4, -0.3]]
        processor.process(&channels, sampleRate: fs)

        XCTAssertEqual(channels[0], [0.2, 0.4, -0.3])

        processor.mode = .instrumental
        processor.reset()
        var channels2: [[Float]] = [[0.2, 0.4, -0.3]]
        processor.process(&channels2, sampleRate: fs)
        XCTAssertEqual(channels2[0], [0.2, 0.4, -0.3])
    }
}
