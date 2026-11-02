//
//  StereoFocusProcessorTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for the band-aware mid/side focus processor (vocal /
/// instrumental isolation buttons).
///
/// Semantics: below the 300 Hz crossover the original stereo signal
/// passes untouched (kick/bass survive every mode); above it, vocal
/// mode keeps the center (mid) and instrumental mode keeps the sides
/// (L-R). Measurements use settled signal tails.
final class StereoFocusProcessorTests: XCTestCase {
    private let fs: Double = 48_000

    private func tone(_ hz: Double, count: Int = 4096, amplitude: Float = 1) -> [Float] {
        (0..<count).map { i -> Float in
            amplitude * sin(Float(2 * .pi * hz * Double(i) / fs))
        }
    }

    private func stereo(_ l: [Float], _ r: [Float]) -> [[Float]] {
        [l, r]
    }

    private func peak(_ samples: [Float], tail: Int = 2048) -> Float {
        samples.suffix(tail).map { abs($0) }.max() ?? 0
    }

    // MARK: - Full passthrough

    func testFullModeIsExactPassthrough() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        var channels = stereo([0.1, -0.2, 0.3], [0.4, 0.5, -0.6])
        let original = channels

        processor.process(&channels, sampleRate: fs)

        XCTAssertEqual(channels, original)
    }

    // MARK: - Vocal mode

    /// Center content in the vocal band passes through unchanged
    /// (L == R means the band split cancels: low + high-mid = original).
    func testVocalsKeepCenterVocalBand() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        let tone = tone(1000)
        var channels = stereo(tone, tone)
        processor.process(&channels, sampleRate: fs)

        XCTAssertEqual(peak(channels[0]), 1, accuracy: 0.15)
        XCTAssertEqual(peak(channels[1]), 1, accuracy: 0.15)
    }

    /// Hard-panned content in the vocal band is largely removed (only
    /// the gentle lowpass's bleed remains).
    func testVocalsRemoveHardPannedVocalBand() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        let tone = tone(1000)
        var channels = stereo(tone, tone.map { -$0 })
        processor.process(&channels, sampleRate: fs)

        XCTAssertLessThan(peak(channels[0]), 0.25)
    }

    /// Low frequencies survive vocal mode even hard-panned - the kick
    /// and bass keep their original stereo image.
    func testVocalsKeepTheLowEnd() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .vocals

        let bass = tone(50)
        var channels = stereo(bass, bass.map { -$0 })
        processor.process(&channels, sampleRate: fs)

        XCTAssertGreaterThan(peak(channels[0]), 0.8)
    }

    // MARK: - Instrumental mode

    /// Center content in the vocal band cancels (classic karaoke).
    func testInstrumentalCancelsCenterVocalBand() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        let tone = tone(1000)
        var channels = stereo(tone, tone)
        processor.process(&channels, sampleRate: fs)

        XCTAssertLessThan(peak(channels[0]), 0.25)
    }

    /// Hard-panned vocal-band content survives (the sides stay).
    func testInstrumentalKeepsHardPannedContent() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        let tone = tone(1000)
        var channels = stereo(tone, tone.map { -$0 })
        processor.process(&channels, sampleRate: fs)

        XCTAssertGreaterThan(peak(channels[0]), 0.7)
    }

    /// Center bass survives the karaoke cancellation (the whole point
    /// of the crossover).
    func testInstrumentalKeepsCenterBass() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        let bass = tone(50)
        var channels = stereo(bass, bass)
        processor.process(&channels, sampleRate: fs)

        XCTAssertGreaterThan(peak(channels[0]), 0.8)
    }

    // MARK: - State across buffers

    /// The split filters carry state across buffer boundaries - the
    /// second buffer is already warmed up (no cold-start dip).
    func testProcessorStatePersistsAcrossCalls() {
        var processor = StereoFocusProcessor(sampleRate: fs)
        processor.mode = .instrumental

        let bass = tone(50)
        var first = stereo(bass, bass)
        processor.process(&first, sampleRate: fs)
        let firstPeak = peak(first[0])

        var second = stereo(bass, bass)
        processor.process(&second, sampleRate: fs)
        let secondPeak = peak(second[0])

        XCTAssertGreaterThanOrEqual(secondPeak, firstPeak * 0.98)
    }

    // MARK: - Mono edge case

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
