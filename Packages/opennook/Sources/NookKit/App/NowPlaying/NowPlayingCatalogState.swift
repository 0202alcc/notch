//
//  NowPlayingCatalogState.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// What a source row should display for one app right now.
public struct NowPlayingDisplayState: Equatable, Sendable {
    /// The track to show, or `nil` when nothing is known (the app never
    /// reported metadata, or its cache went stale after long silence).
    public let track: NowPlayingTrack?

    /// Whether the app is audible right now. `true` even when `track`
    /// is nil (an app can play without ever reporting metadata).
    public let isPlaying: Bool
}

/// Pure core of the now-playing catalog: fuses metadata updates with
/// per-app activity into per-row display state.
///
/// The rules:
///   1. `apply(update:)` stores the latest track per bundle ID. Only
///      apps that report metadata get records - apps that never report
///      (Serato) never appear, and activity alone fabricates nothing.
///   2. `markActivity` records when each app was last *audible*.
///      Monitors call it on every tick while the app is producing
///      audio, so `lastAudibleAt` tracks continuous playback.
///   3. Display: an audible app shows its track while the track is
///      *fresh* (audible within ``clearAfterInterval`` - a track seen
///      ages ago is stale and shows as nothing); a silent app's track
///      stays visible through a pause within ``graceInterval``, then
///      hides.
///
/// Time is injected (`now`, `at`) - no wall-clock reads, no sleeps.
public struct NowPlayingCatalogState: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        var track: NowPlayingTrack
        /// Last time the app was reported audible. `nil` while the
        /// record exists but has never been heard.
        var lastAudibleAt: TimeInterval?
    }

    private var records: [String: Record] = [:]

    /// How long a paused app's track stays visible after it last made
    /// sound.
    public let graceInterval: TimeInterval
    /// How long a track stays fresh enough to display at all - an
    /// audible-but-ancient track is treated as unknown.
    public let clearAfterInterval: TimeInterval

    public init(
        graceInterval: TimeInterval = 4,
        clearAfterInterval: TimeInterval = 10
    ) {
        self.graceInterval = graceInterval
        self.clearAfterInterval = clearAfterInterval
    }

    // MARK: - Mutations

    /// Store the latest metadata for an app. Idempotent for identical
    /// updates; later tracks replace earlier ones.
    public mutating func apply(update: NowPlayingUpdate) {
        guard let track = update.track else { return }

        if var record = records[update.bundleIdentifier] {
            record.track = track
            records[update.bundleIdentifier] = record
        } else {
            records[update.bundleIdentifier] = Record(
                track: track,
                lastAudibleAt: nil
            )
        }
    }

    /// Record whether an app was audible at `at`. Activity for an
    /// unknown app does NOT fabricate a record: activity without
    /// metadata is fine, but metadata without a source is a
    /// hallucination.
    public mutating func markActivity(
        bundleIdentifier: String,
        active: Bool,
        at: TimeInterval
    ) {
        guard records[bundleIdentifier] != nil, active else {
            return
        }
        records[bundleIdentifier]?.lastAudibleAt = at
    }

    // MARK: - Resolution

    /// Compute what every known app's row should display at `now`,
    /// given the current per-app activity map (bundle ID → audible
    /// right now, from tap levels and source player states).
    public func displayStates(
        now: TimeInterval,
        activity: [String: Bool]
    ) -> [String: NowPlayingDisplayState] {
        var states: [String: NowPlayingDisplayState] = [:]

        // Apps that are audible but have never reported metadata still
        // get a playing state - the row shows "playing" with no title,
        // never a guessed track. This does not fabricate a record.
        for (bundleID, active) in activity where active {
            if records[bundleID] == nil {
                states[bundleID] = NowPlayingDisplayState(
                    track: nil,
                    isPlaying: true
                )
            }
        }

        for (bundleID, record) in records {
            let active = activity[bundleID] ?? false

            if active {
                let fresh = record.lastAudibleAt.map {
                    now - $0 <= clearAfterInterval
                } ?? false
                states[bundleID] = NowPlayingDisplayState(
                    track: fresh ? record.track : nil,
                    isPlaying: true
                )
                continue
            }

            guard let lastAudible = record.lastAudibleAt else {
                // Known track, never seen audible - nothing to show.
                continue
            }

            if now - lastAudible <= graceInterval {
                states[bundleID] = NowPlayingDisplayState(
                    track: record.track,
                    isPlaying: false
                )
            }
            // Between grace and clear: silent, shown as nothing.
        }

        return states
    }
}
