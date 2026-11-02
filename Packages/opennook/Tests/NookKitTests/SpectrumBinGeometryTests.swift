//
//  SpectrumBinGeometryTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for mapping spectrum bins onto the EQ graph's
/// log-frequency axis: the background columns that light up with the
/// source's live energy.
final class SpectrumBinGeometryTests: XCTestCase {
    /// One x position (0...1) per bin, log-spaced across the range.
    func testPositionsAreLogSpacedAndMonotonic() {
        let positions = SpectrumBinGeometry.normalizedCenters(
            binCount: 32, minHz: 60, maxHz: 20000
        )

        XCTAssertEqual(positions.count, 32)

        // Log-even spacing: consecutive ratios constant.
        let deltas = zip(positions, positions.dropFirst()).map { $1 - $0 }
        for (index, delta) in deltas.enumerated() {
            XCTAssertEqual(delta, deltas[0], accuracy: 0.002, "bin \(index)")
        }

        // All within the axis, monotonic increasing.
        XCTAssertTrue(positions.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(positions, positions.sorted())
    }

    /// The first center sits at the range's log midpoint (60 Hz on a
    /// 20 Hz - 20 kHz axis is NOT the left edge).
    func testFirstCenterAccountsForMinHzOffset() {
        let positions = SpectrumBinGeometry.normalizedCenters(
            binCount: 32, minHz: 60, maxHz: 20000
        )
        let expected = (log10(60) - log10(20)) / (log10(20000) - log10(20))
            + 0.5 * ((log10(20000) - log10(60)) / (log10(20000) - log10(20))) / 32

        XCTAssertEqual(positions[0], expected, accuracy: 0.01)
        XCTAssertGreaterThan(positions[0], 0.05, "60 Hz must not collapse to the left edge")
    }

    /// Degenerate inputs don't divide by zero. A single bin centers on
    /// its own range's log midpoint (60 Hz..20 kHz midpoint maps to
    /// ~0.58 on the 20 Hz axis).
    func testSingleBin() {
        let positions = SpectrumBinGeometry.normalizedCenters(
            binCount: 1, minHz: 60, maxHz: 20000
        )
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0], 0.5795, accuracy: 0.01)
    }
}
