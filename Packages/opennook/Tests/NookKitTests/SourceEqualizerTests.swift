//
//  SourceEqualizerTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import CoreAudio
import XCTest

@testable import NookKit

/// Scratch tests for the per-source three-band EQ (lows/mids/highs
/// "potentiometers"), written before implementation.
///
/// The route-rebuild preservation pattern is the known bug farm (UID
/// and volume were each silently dropped by a rebuild path once) - so
/// EQ preservation across every mutation path is asserted here FIRST.
@MainActor
final class SourceEqualizerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.SourceEqualizerTests")
        defaults.removePersistentDomain(forName: "test.SourceEqualizerTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.SourceEqualizerTests")
        defaults = nil
        super.tearDown()
    }

    private func makeRoutedRoute(deviceID: AudioDeviceID = 42) -> SourceRoute {
        SourceRoute(
            sourceObjectID: 1,
            bundleIdentifier: "com.example.music",
            applicationName: "Music",
            outputDeviceID: deviceID,
            enabled: true
        )
    }

    private func store() -> RouteStore {
        RouteStore(defaults: defaults)
    }

    // MARK: - Defaults

    func testEQDefaultsToFlatZeroDB() {
        let route = makeRoutedRoute()
        XCTAssertEqual(route.eqLowDB, 0)
        XCTAssertEqual(route.eqMidDB, 0)
        XCTAssertEqual(route.eqHighDB, 0)
    }

    /// Records written before EQ existed decode with flat EQ instead of
    /// failing the whole store.
    func testLegacyJSONWithoutEQDecodesFlat() throws {
        let legacy = """
        {
          "sourceObjectID": 251,
          "bundleIdentifier": "com.serato.seratodj",
          "applicationName": "Serato DJ Pro",
          "outputDeviceID": 251,
          "enabled": true,
          "volume": 0.5
        }
        """
        let route = try JSONDecoder().decode(
            SourceRoute.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(route.eqLowDB, 0)
        XCTAssertEqual(route.eqMidDB, 0)
        XCTAssertEqual(route.eqHighDB, 0)
    }

    // MARK: - Preservation across every mutation path

    private func eqRoute(_ low: Double, _ mid: Double, _ high: Double) -> SourceRoute {
        SourceRoute(
            sourceObjectID: 1,
            bundleIdentifier: "com.example.music",
            applicationName: "Music",
            outputDeviceID: 42,
            enabled: true,
            volume: 0.7,
            eqLowDB: low,
            eqMidDB: mid,
            eqHighDB: high
        )
    }

    func testEQSurvivesUpsertCollision() {
        let store = store()
        store.upsertRoute(eqRoute(-3, 1.5, 6))

        // Source restarts: re-discovered with all defaults.
        store.upsertRoute(SourceRoute(
            sourceObjectID: 200,
            bundleIdentifier: "com.example.music",
            applicationName: "Music"
        ))

        let stored = store.routes["com.example.music"]
        XCTAssertEqual(stored?.eqLowDB, -3)
        XCTAssertEqual(stored?.eqMidDB, 1.5)
        XCTAssertEqual(stored?.eqHighDB, 6)
    }

    func testEQSurvivesSetOutput() {
        let store = store()
        store.upsertRoute(eqRoute(-3, 1.5, 6))
        store.setOutput(forBundleIdentifier: "com.example.music", deviceID: 99)

        XCTAssertEqual(store.routes["com.example.music"]?.eqLowDB, -3)
        XCTAssertEqual(store.routes["com.example.music"]?.eqMidDB, 1.5)
        XCTAssertEqual(store.routes["com.example.music"]?.eqHighDB, 6)
    }

    func testEQSurvivesSetEnabled() {
        let store = store()
        store.upsertRoute(eqRoute(-3, 1.5, 6))
        store.setEnabled(forBundleIdentifier: "com.example.music", enabled: false)

        XCTAssertEqual(store.routes["com.example.music"]?.eqLowDB, -3)
        XCTAssertEqual(store.routes["com.example.music"]?.eqMidDB, 1.5)
        XCTAssertEqual(store.routes["com.example.music"]?.eqHighDB, 6)
    }

    func testEQSurvivesSetVolume() {
        let store = store()
        store.upsertRoute(eqRoute(-3, 1.5, 6))
        store.setVolume(forBundleIdentifier: "com.example.music", volume: 0.2)

        XCTAssertEqual(store.routes["com.example.music"]?.eqLowDB, -3)
        XCTAssertEqual(store.routes["com.example.music"]?.eqMidDB, 1.5)
        XCTAssertEqual(store.routes["com.example.music"]?.eqHighDB, 6)
    }

    func testEQSurvivesPersistenceRoundTrip() {
        let original = store()
        original.upsertRoute(eqRoute(-6, 0, 9))

        let reloaded = store()
        XCTAssertEqual(reloaded.routes["com.example.music"]?.eqLowDB, -6)
        XCTAssertEqual(reloaded.routes["com.example.music"]?.eqHighDB, 9)
    }

    // MARK: - setEqualizer

    func testSetEqualizerClampsToLimit() {
        let store = store()
        store.upsertRoute(makeRoutedRoute())

        store.setEqualizer(
            forBundleIdentifier: "com.example.music", band: .low, db: 99
        )
        XCTAssertEqual(store.routes["com.example.music"]?.eqLowDB, 12)

        store.setEqualizer(
            forBundleIdentifier: "com.example.music", band: .high, db: -99
        )
        XCTAssertEqual(store.routes["com.example.music"]?.eqHighDB, -12)
    }

    func testSetEqualizerIsPerBand() {
        let store = store()
        store.upsertRoute(makeRoutedRoute())

        store.setEqualizer(
            forBundleIdentifier: "com.example.music", band: .mid, db: 4
        )

        let route = store.routes["com.example.music"]
        XCTAssertEqual(route?.eqMidDB, 4)
        XCTAssertEqual(route?.eqLowDB, 0)
        XCTAssertEqual(route?.eqHighDB, 0)
    }

    // MARK: - Band model

    func testEqualizerBandSpecs() {
        XCTAssertEqual(EQBand.allCases, [.low, .mid, .high])
        XCTAssertEqual(EQBand.low.frequencyHz, 150)
        XCTAssertEqual(EQBand.mid.frequencyHz, 1000)
        XCTAssertEqual(EQBand.high.frequencyHz, 6000)
    }

    /// Knob position (0...1) maps linearly to -12...+12 dB, 0.5 = flat.
    func testKnobPositionMapping() {
        XCTAssertEqual(EQBand.db(forKnobPosition: 0.0), -12)
        XCTAssertEqual(EQBand.db(forKnobPosition: 0.5), 0)
        XCTAssertEqual(EQBand.db(forKnobPosition: 1.0), 12)
        XCTAssertEqual(EQBand.db(forKnobPosition: 0.75), 6)

        XCTAssertEqual(EQBand.knobPosition(forDB: -12), 0)
        XCTAssertEqual(EQBand.knobPosition(forDB: 0), 0.5)
        XCTAssertEqual(EQBand.knobPosition(forDB: 12), 1)
    }

    func testDBClamping() {
        XCTAssertEqual(EQBand.clampDB(50), 12)
        XCTAssertEqual(EQBand.clampDB(-50), -12)
        XCTAssertEqual(EQBand.clampDB(3.7), 3.7)
    }
}
