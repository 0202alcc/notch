//
//  ListeningModeModelTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for the AirPods listening-mode slider (written before
/// implementation).
///
/// The model maps the four discrete AirPods noise-control modes onto a
/// 0...1 slider with evenly spaced stops, and parses mode names as they
/// appear in the Control Center AX hierarchy.
@MainActor
final class ListeningModeModelTests: XCTestCase {
    let allModes: [ListeningMode] = [
        .off, .transparency, .adaptive, .noiseCancellation,
    ]

    // MARK: - Ordering

    /// Stop order is fixed: off < transparency < adaptive < ANC -
    /// dragging right always means "more cancellation".
    func testOrderingIsFixed() {
        XCTAssertEqual(ListeningMode.allCases, allModes)
    }

    // MARK: - Positions

    func testPositionsAreEvenlySpaced() {
        let model = ListeningModeModel(available: allModes)

        XCTAssertEqual(model.position(of: .off), 0)
        XCTAssertEqual(model.position(of: .transparency) ?? -1, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(model.position(of: .adaptive) ?? -1, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(model.position(of: .noiseCancellation), 1)
    }

    /// A single available mode is a degenerate slider pinned to 0.
    func testSingleModePositionIsZero() {
        let model = ListeningModeModel(available: [.transparency])
        XCTAssertEqual(model.position(of: .transparency), 0)
    }

    // MARK: - Snapping

    /// A drag position snaps to the nearest stop - that is how the
    /// slider delivers "precise" mode selection on a discrete platform.
    func testSnappingToNearestStop() {
        let model = ListeningModeModel(available: allModes)

        XCTAssertEqual(model.mode(at: 0.0), .off)
        XCTAssertEqual(model.mode(at: 0.1), .off)           // 0.3 -> round 0
        XCTAssertEqual(model.mode(at: 0.34), .transparency) // 1.02 -> round 1
        XCTAssertEqual(model.mode(at: 0.5), .adaptive)      // 1.5 -> round 2
        XCTAssertEqual(model.mode(at: 0.67), .adaptive)     // 2.01 -> round 2
        XCTAssertEqual(model.mode(at: 0.8), .adaptive)      // 2.4 -> round 2
        XCTAssertEqual(model.mode(at: 0.9), .noiseCancellation) // 2.7 -> round 3
        XCTAssertEqual(model.mode(at: 1.0), .noiseCancellation)
    }

    /// Two-mode slider: the midpoint splits the two stops.
    func testTwoModeSnapping() {
        let model = ListeningModeModel(available: [.transparency, .adaptive])
        XCTAssertEqual(model.mode(at: 0.49), .transparency)
        XCTAssertEqual(model.mode(at: 0.51), .adaptive)
    }

    /// Out-of-range positions clamp, not crash.
    func testClamping() {
        let model = ListeningModeModel(available: allModes)
        XCTAssertEqual(model.mode(at: -0.5), .off)
        XCTAssertEqual(model.mode(at: 1.5), .noiseCancellation)
    }

    // MARK: - AX parsing

    /// Mode names arrive exactly as Control Center renders them.
    func testParsingAXDescriptions() {
        XCTAssertEqual(ListeningMode(axDescription: "Off"), .off)
        XCTAssertEqual(ListeningMode(axDescription: "Transparency"), .transparency)
        XCTAssertEqual(ListeningMode(axDescription: "Adaptive"), .adaptive)
        XCTAssertEqual(ListeningMode(axDescription: "Noise Cancellation"), .noiseCancellation)
    }

    /// Unknown descriptors ("Not Available", spatial-audio labels, etc.)
    /// must parse to nil, never to a wrong mode.
    func testUnknownAXDescriptionsParseToNil() {
        XCTAssertNil(ListeningMode(axDescription: "Not Available"))
        XCTAssertNil(ListeningMode(axDescription: "On"))
        XCTAssertNil(ListeningMode(axDescription: ""))
    }
}
