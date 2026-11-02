//
//  EQResponseCurveMathTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for the response-curve math that renders the live EQ
/// graph above the nook's potentiometers: RBJ biquad magnitudes, the
/// same formulas AVAudioUnitEQ implements.
final class EQResponseCurveMathTests: XCTestCase {
    /// Flat EQ: the response is 0 dB at every frequency.
    func testFlatEQIsZeroEverywhere() {
        let curve = EQResponseCurveMath.combinedResponseDB(low: 0, mid: 0, high: 0)
        XCTAssertEqual(curve.count, EQResponseCurveMath.sampleCount)
        for (index, db) in curve.enumerated() where abs(db) > 0.15 {
            XCTFail("flat EQ gave \(db) dB at sample \(index)")
        }
    }

    /// A fully-boosted low shelf reaches ~+12 dB at the bottom of the
    /// spectrum and stays ~0 dB above the corner.
    func testBoostedLowShelf() {
        let curve = EQResponseCurveMath.combinedResponseDB(low: 12, mid: 0, high: 0)
        let dbAt30Hz = EQResponseCurveMath.responseDB(band: .low, db: 12, frequencyHz: 30)
        let dbAt2kHz = EQResponseCurveMath.responseDB(band: .low, db: 12, frequencyHz: 2000)

        XCTAssertEqual(dbAt30Hz, 12, accuracy: 0.4)
        XCTAssertEqual(dbAt2kHz, 0, accuracy: 0.4)
        XCTAssertEqual(curve.first ?? 0, 12, accuracy: 0.4)
    }

    /// A cut shelf mirrors the boost (symmetric around 0). Note: a
    /// slope-1 shelf hasn't fully converged to its asymptote 2 octaves
    /// past the corner - the real AVAudioUnitEQ behaves identically -
    /// hence the 0.6 dB tolerance.
    func testCutShelfMirrorsBoost() {
        let boost = EQResponseCurveMath.responseDB(band: .high, db: 12, frequencyHz: 12000)
        let cut = EQResponseCurveMath.responseDB(band: .high, db: -12, frequencyHz: 12000)

        XCTAssertEqual(boost, 12, accuracy: 0.6)
        XCTAssertEqual(cut, -12, accuracy: 0.6)
    }

    /// The mid bell peaks at its center frequency.
    func testMidBellPeaksAtCenter() {
        let at1k = EQResponseCurveMath.responseDB(band: .mid, db: 6, frequencyHz: 1000)
        let at200 = EQResponseCurveMath.responseDB(band: .mid, db: 6, frequencyHz: 200)

        XCTAssertEqual(at1k, 6, accuracy: 0.3)
        XCTAssertLessThan(at200, 2.0, "the bell must taper away from center")
    }

    /// The combined curve is the SUM of the three band responses.
    func testCombinedIsSumOfBands() {
        let f = 150.0
        let low = EQResponseCurveMath.responseDB(band: .low, db: -6, frequencyHz: f)
        let mid = EQResponseCurveMath.responseDB(band: .mid, db: 3, frequencyHz: f)
        let high = EQResponseCurveMath.responseDB(band: .high, db: 0, frequencyHz: f)

        let curve = EQResponseCurveMath.combinedResponseDB(low: -6, mid: 3, high: 0)
        // f=150Hz is the low shelf's CORNER - responses vary fast there,
        // so the nearest-sample lookup tolerates more slop.
        let nearest = curve.minusNearestSample(toHz: f)
        XCTAssertEqual(nearest, low + mid + high, accuracy: 0.6)
    }
}

private extension [Double] {
    /// Value at the log-spaced sample nearest a given frequency.
    func minusNearestSample(toHz f: Double) -> Double {
        let logF = log10(f)
        let logMin = log10(20.0)
        let logMax = log10(20000.0)
        let index = Int(
            ((logF - logMin) / (logMax - logMin)) * Double(count - 1)
                .rounded()
        )
        return self[Swift.min(Swift.max(index, 0), count - 1)]
    }
}
