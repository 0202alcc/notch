//
//  RouteStoreTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 10/31/26.
//

import CoreAudio
import XCTest

@testable import NookKit

/// `RouteStore` is the source of truth for split-audio-routing decisions:
/// main-actor mutations publish an immutable snapshot that the audio
/// thread reads lock-free, and everything persists to `UserDefaults`.
///
/// These tests lock the pre-routing-fix semantics (Phase 0 of
/// docs/split-audio-routing.md) so the sample-path and mute-behavior
/// changes cannot silently drift them.
@MainActor
final class RouteStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.RouteStoreTests")
        defaults.removePersistentDomain(forName: "test.RouteStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.RouteStoreTests")
        defaults = nil
        super.tearDown()
    }

    private func makeRoute(
        objectID: AudioObjectID,
        bundleID: String? = "com.example.music",
        name: String = "Music",
        deviceID: AudioDeviceID? = nil,
        enabled: Bool = false
    ) -> SourceRoute {
        SourceRoute(
            sourceObjectID: objectID,
            bundleIdentifier: bundleID,
            applicationName: name,
            outputDeviceID: deviceID,
            enabled: enabled
        )
    }

    /// Re-upserting a source under the same bundle ID (e.g. the app
    /// restarted and Core Audio recycled the object ID) must keep the
    /// user's chosen device.
    func testUpsertPreservesExistingDeviceOnBundleIDCollision() {
        let store = RouteStore(defaults: defaults)
        let original = makeRoute(objectID: 100, deviceID: 42, enabled: true)
        store.upsertRoute(original)

        let restarted = makeRoute(objectID: 200, deviceID: nil)
        store.upsertRoute(restarted)

        let stored = store.routes["com.example.music"]
        XCTAssertEqual(stored?.outputDeviceID, 42)
        XCTAssertEqual(stored?.enabled, true)
        XCTAssertEqual(stored?.sourceObjectID, 200)
    }

    /// A brand-new bundle ID inserts as-is, no inherited state.
    func testUpsertNewRouteStandsAlone() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, deviceID: 7))

        let other = makeRoute(objectID: 2, bundleID: "com.example.other")
        store.upsertRoute(other)

        XCTAssertEqual(store.routes["com.example.other"]?.outputDeviceID, nil)
        XCTAssertEqual(store.routes["com.example.other"]?.enabled, false)
        XCTAssertEqual(store.routes["com.example.music"]?.outputDeviceID, 7)
    }

    func testSetOutputUpdatesOnlyTargetedRoute() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, bundleID: "com.example.a"))
        store.upsertRoute(makeRoute(objectID: 2, bundleID: "com.example.b"))

        store.setOutput(forBundleIdentifier: "com.example.a", deviceID: 9)

        XCTAssertEqual(store.routes["com.example.a"]?.outputDeviceID, 9)
        XCTAssertNil(store.routes["com.example.b"]?.outputDeviceID)
    }

    func testSetEnabledTogglesOnlyTargetedRoute() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, bundleID: "com.example.a"))
        store.upsertRoute(makeRoute(objectID: 2, bundleID: "com.example.b"))

        store.setEnabled(forBundleIdentifier: "com.example.a", enabled: true)

        XCTAssertEqual(store.routes["com.example.a"]?.enabled, true)
        XCTAssertEqual(store.routes["com.example.b"]?.enabled, false)
    }

    /// Disabling a source keeps its device selection so the user can
    /// toggle back on without re-picking.
    func testSetEnabledKeepsDeviceSelection() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, deviceID: 5, enabled: true))

        store.setEnabled(forBundleIdentifier: "com.example.music", enabled: false)

        let stored = store.routes["com.example.music"]
        XCTAssertEqual(stored?.enabled, false)
        XCTAssertEqual(stored?.outputDeviceID, 5)
    }

    /// The durable device UID survives a source re-discovery, like the
    /// cached ID does.
    func testUpsertPreservesDeviceUIDOnBundleIDCollision() {
        let store = RouteStore(defaults: defaults)
        var original = makeRoute(objectID: 100, deviceID: 42, enabled: true)
        original = SourceRoute(
            sourceObjectID: 100,
            bundleIdentifier: "com.example.music",
            applicationName: "Music",
            outputDeviceID: 42,
            outputDeviceUID: "UID-AIRPODS",
            enabled: true
        )
        store.upsertRoute(original)

        let restarted = makeRoute(objectID: 200)
        store.upsertRoute(restarted)

        let stored = store.routes["com.example.music"]
        XCTAssertEqual(stored?.outputDeviceUID, "UID-AIRPODS")
        XCTAssertEqual(stored?.outputDeviceID, 42)
    }

    /// Routes persisted before UID tracking existed must decode with
    /// `outputDeviceUID == nil` instead of failing the whole store.
    func testLegacyRouteJSONWithoutUIDDecodes() throws {
        let legacy = """
        {
          "sourceObjectID": 251,
          "bundleIdentifier": "com.serato.seratodj",
          "applicationName": "Serato DJ Pro",
          "outputDeviceID": 251,
          "enabled": true
        }
        """
        let route = try JSONDecoder().decode(
            SourceRoute.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(route.bundleIdentifier, "com.serato.seratodj")
        XCTAssertEqual(route.outputDeviceID, 251)
        XCTAssertNil(route.outputDeviceUID)
        XCTAssertEqual(route.enabled, true)
    }

    /// The audio thread reads the snapshot off the main actor - the
    /// published snapshot must be visible to non-main readers the
    /// moment the mutation returns.
    func testSnapshotVisibleFromNonMainThread() throws {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 77, deviceID: 88, enabled: true))
        store.setRoutingEnabled(true)

        let expectation = expectation(description: "audio-thread read")
        DispatchQueue.global(qos: .userInteractive).async {
            let byID = store.route(forSourceObjectID: 77)
            let byBundle = store.route(forBundleIdentifier: "com.example.music")
            let enabled = store.isRoutingEnabled

            DispatchQueue.main.async {
                XCTAssertEqual(byID?.outputDeviceID, 88)
                XCTAssertEqual(byBundle?.outputDeviceID, 88)
                XCTAssertTrue(enabled)
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 5)
    }

    func testPersistenceRoundTrip() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, deviceID: 42, enabled: true))
        store.setRoutingEnabled(true)

        let reloaded = RouteStore(defaults: defaults)

        XCTAssertEqual(
            reloaded.routes["com.example.music"]?.outputDeviceID,
            42
        )
        XCTAssertEqual(reloaded.routes["com.example.music"]?.enabled, true)
        XCTAssertEqual(reloaded.isRoutingEnabled, true)
    }

    func testRoutingEnabledDefaultsToOff() {
        let store = RouteStore(defaults: defaults)

        XCTAssertFalse(store.isRoutingEnabled)
        XCTAssertFalse(store.routingEnabled)
    }

    /// Legacy stores (before per-source picks implied the master switch)
    /// hold enabled routes with no master record. Loading such a store
    /// honors the visible intent: master on.
    func testLoadAutoHealsMasterSwitchWhenRoutesExist() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, deviceID: 42))
        store.setEnabled(forBundleIdentifier: "com.example.music", enabled: true)

        // The mutating ops above deliberately never touch the master.
        XCTAssertFalse(store.routingEnabled)

        let reloaded = RouteStore(defaults: defaults)
        XCTAssertTrue(reloaded.isRoutingEnabled)
    }

    /// An explicit master-off must not be overridden by the auto-heal.
    func testExplicitMasterOffNotOverriddenByHeal() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 1, deviceID: 42))
        store.setEnabled(forBundleIdentifier: "com.example.music", enabled: true)
        store.setRoutingEnabled(false)

        let reloaded = RouteStore(defaults: defaults)
        XCTAssertFalse(reloaded.isRoutingEnabled)
    }

    /// `nil` bundle IDs fall back to an object-ID-derived stable key
    /// and stay addressable through `route(forSourceObjectID:)`.
    func testRouteWithoutBundleIDKeyedByObjectID() {
        let store = RouteStore(defaults: defaults)
        store.upsertRoute(makeRoute(objectID: 123, bundleID: nil, deviceID: 4))

        let byID = store.route(forSourceObjectID: 123)
        XCTAssertEqual(byID?.outputDeviceID, 4)
        XCTAssertNil(store.route(forBundleIdentifier: "com.example.music"))
    }
}
