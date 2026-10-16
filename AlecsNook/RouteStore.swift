//
//  RouteStore.swift
//  AlecsNook
//
//  Created by Alec Candidato on 8/7/26.
//

import Combine
import CoreAudio
import Foundation
import os

/// Persistent store of `SourceRoute`s keyed by source identifier.
///
/// The store is the source of truth for routing decisions. It is read
/// on the audio thread (via `route(forSourceObjectID:)` and
/// `route(forBundleIdentifier:)`) and written on the main actor. To
/// keep both sides lock-free we publish a single immutable snapshot on
/// every change; readers grab the current snapshot under a brief
/// `OSAllocatedUnfairLock` and consult it without further synchronization.
///
/// Snapshots are also persisted to `UserDefaults` so routes survive
/// app relaunch. Persistence is best-effort and never blocks the
/// audio path.
final class RouteStore: ObservableObject {
    nonisolated(unsafe) static let shared = RouteStore()

    /// `true` indicates the user wants any captured source audio to be
    /// replayed by `AudioRouter`. `false` means "system default for
    /// everything" — AlecsNook still taps for visualization but does not
    /// replay, so there is no echo. This is the safe default until the
    /// user explicitly enables routing.
    @Published var routingEnabled: Bool = false

    /// Latest snapshot of every known route, keyed by `SourceRoute.stableKey`.
    /// Published so the SwiftUI row pickers re-render when routes change.
    @Published private(set) var routes: [String: SourceRoute] = [:]

    /// Lock-free snapshot consumed by the audio thread. Updated from
    /// the main actor; reads from any thread are safe.
    private let snapshotLock =
        OSAllocatedUnfairLock<Snapshot>(initialState: .empty)
    private var snapshot: Snapshot { snapshotLock.withLock { $0 } }

    private struct Snapshot {
        var routesByObjectID: [AudioObjectID: SourceRoute]
        var routesByBundleID: [String: SourceRoute]
        var routingEnabled: Bool

        static let empty = Snapshot(
            routesByObjectID: [:],
            routesByBundleID: [:],
            routingEnabled: false
        )
    }

    private let defaults: UserDefaults
    private let defaultsKey = "AlecsNook.SourceRoutes.v1"
    private let routingEnabledKey = "AlecsNook.RoutingEnabled.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Lookup

    /// Look up the route for an audio-process `AudioObjectID`.
    /// Called from the audio thread.
    nonisolated func route(forSourceObjectID id: AudioObjectID)
        -> SourceRoute?
    {
        snapshotLock.withLock { $0.routesByObjectID[id] }
    }

    /// Look up the route by bundle identifier. Used when the source's
    /// `AudioObjectID` has been recycled (after a process restart) but
    /// the bundle identifier is unchanged.
    nonisolated func route(forBundleIdentifier bundleID: String?)
        -> SourceRoute?
    {
        guard let bundleID else { return nil }
        return snapshotLock.withLock { $0.routesByBundleID[bundleID] }
    }

    /// Whether the user wants `AudioRouter` to actually replay audio.
    /// Read from the audio thread.
    nonisolated var isRoutingEnabled: Bool {
        snapshotLock.withLock { $0.routingEnabled }
    }

    // MARK: - Mutation (main actor)

    /// Insert or replace the route for a source. If the source's
    /// bundle identifier matches an existing route, the existing
    /// `outputDeviceID` / `enabled` are preserved so the user doesn't
    /// lose their routing preference when an app restarts and gets a
    /// new `AudioObjectID`.
    @MainActor
    func upsertRoute(_ route: SourceRoute) {
        let key = route.stableKey

        let resolved: SourceRoute
        if let existing = routes[key] {
            resolved = SourceRoute(
                sourceObjectID: route.sourceObjectID,
                bundleIdentifier: route.bundleIdentifier,
                applicationName: route.applicationName,
                outputDeviceID: route.outputDeviceID
                    ?? existing.outputDeviceID,
                enabled: route.enabled
            )
        } else {
            resolved = route
        }

        routes[key] = resolved
        publishSnapshot()
        persist()
    }

    /// Update just the `outputDeviceID` for an existing route.
    @MainActor
    func setOutput(
        forBundleIdentifier bundleID: String,
        deviceID: AudioDeviceID?
    ) {
        let key = bundleID
        guard var route = routes[key] else { return }
        route = SourceRoute(
            sourceObjectID: route.sourceObjectID,
            bundleIdentifier: route.bundleIdentifier,
            applicationName: route.applicationName,
            outputDeviceID: deviceID,
            enabled: route.enabled
        )
        routes[key] = route
        publishSnapshot()
        persist()
    }

    /// Enable or disable routing for a specific source. `enabled` here
    /// means "replay this source through `AudioRouter`". Disabling a
    /// source with a route still leaves the `outputDeviceID` set so the
    /// user can toggle it back on later.
    @MainActor
    func setEnabled(
        forBundleIdentifier bundleID: String,
        enabled: Bool
    ) {
        let key = bundleID
        guard let route = routes[key] else { return }
        let updated = SourceRoute(
            sourceObjectID: route.sourceObjectID,
            bundleIdentifier: route.bundleIdentifier,
            applicationName: route.applicationName,
            outputDeviceID: route.outputDeviceID,
            enabled: enabled
        )
        routes[key] = updated
        publishSnapshot()
        persist()
    }

    /// Toggle the global routing switch. When off, `AudioRouter` is a
    /// pass-through; the audio thread reads `isRoutingEnabled` and
    /// skips replay.
    @MainActor
    func setRoutingEnabled(_ enabled: Bool) {
        routingEnabled = enabled
        publishSnapshot()
        defaults.set(enabled, forKey: routingEnabledKey)
    }

    // MARK: - Persistence

    private func publishSnapshot() {
        let byObjectID: [AudioObjectID: SourceRoute] = routes
            .values
            .reduce(into: [:]) { acc, route in
                acc[route.sourceObjectID] = route
            }

        let byBundleID: [String: SourceRoute] = routes
            .values
            .reduce(into: [:]) { acc, route in
                if let bundleID = route.bundleIdentifier {
                    acc[bundleID] = route
                }
            }

        // Capture the `routingEnabled` value here so the closure
        // handed to `withLock` is fully self-contained —
        // `OSAllocatedUnfairLock`'s closure is `Sendable`, so it
        // can't reach back into the main actor.
        let enabled = routingEnabled

        snapshotLock.withLock { state in
            state.routesByObjectID = byObjectID
            state.routesByBundleID = byBundleID
            state.routingEnabled = enabled
        }
    }

    private func load() {
        if let data = defaults.data(forKey: defaultsKey) {
            do {
                let decoded = try JSONDecoder().decode(
                    [String: SourceRoute].self,
                    from: data
                )
                routes = decoded
            } catch {
                NSLog(
                    "RouteStore: failed to decode persisted routes: "
                    + "\(error)"
                )
            }
        }
        routingEnabled =
            defaults.bool(forKey: routingEnabledKey)

        publishSnapshot()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(routes)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            NSLog(
                "RouteStore: failed to persist routes: \(error)"
            )
        }
    }
}