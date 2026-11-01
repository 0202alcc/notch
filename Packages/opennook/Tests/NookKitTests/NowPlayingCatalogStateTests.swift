//
//  NowPlayingCatalogStateTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 11/1/26.
//

import XCTest

@testable import NookKit

/// Scratch tests for the now-playing metadata feature (written before
/// implementation, per the test-first plan).
///
/// The catalog answers "what is playing from where" by fusing three
/// signals:
///   1. metadata updates from per-app sources (AppleScript bridge now,
///      the MediaRemote helper later)
///   2. per-app activity (tap levels / source player state)
///   3. a per-bundle-ID cache with grace + clear intervals
///
/// Time is injected everywhere so tests never sleep.
@MainActor
final class NowPlayingCatalogStateTests: XCTestCase {
    private let bundleA = "com.spotify.client"
    private let bundleB = "com.apple.Music"

    private func track(
        title: String = "Don't Play",
        artist: String? = "Jungle",
        album: String? = "Volcano"
    ) -> NowPlayingTrack {
        NowPlayingTrack(title: title, artist: artist, album: album)
    }

    private func update(
        bundleID: String = "com.spotify.client",
        track: NowPlayingTrack? = NowPlayingCatalogStateTests.defaultTrack,
        isPlaying: Bool = true,
        at: TimeInterval = 0
    ) -> NowPlayingUpdate {
        NowPlayingUpdate(
            bundleIdentifier: bundleID,
            track: track,
            isPlaying: isPlaying,
            timestamp: at
        )
    }

    private static let bundleAStatic = "com.spotify.client"
    private static let defaultTrack = NowPlayingTrack(
        title: "Don't Play",
        artist: "Jungle",
        album: "Volcano"
    )

    private func makeCatalog(
        grace: TimeInterval = 4,
        clearAfter: TimeInterval = 10
    ) -> NowPlayingCatalogState {
        NowPlayingCatalogState(
            graceInterval: grace,
            clearAfterInterval: clearAfter
        )
    }

    // MARK: - Display basics

    /// An untouched catalog shows nothing for anyone.
    func testFreshCatalogDisplaysNothing() {
        let catalog = makeCatalog()

        let states = catalog.displayStates(
            now: 100,
            activity: [bundleA: true]
        )

        XCTAssertNil(states[bundleA]?.track)
        XCTAssertNil(states[bundleB])
    }

    /// Metadata + activity => the row displays the track and is playing.
    func testMetadataPlusActivityShowsPlayingTrack() {
        var catalog = makeCatalog()
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)

        let states = catalog.displayStates(now: 1, activity: [bundleA: true])

        let state = states[bundleA]
        XCTAssertEqual(state?.track, track())
        XCTAssertEqual(state?.isPlaying, true)
    }

    /// Activity without metadata (e.g. an app that only produces audio)
    /// shows a playing row with no title - never a guessed track.
    func testActivityWithoutMetadataShowsNoTrack() {
        var catalog = makeCatalog()
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)

        let states = catalog.displayStates(now: 1, activity: [bundleA: true])

        XCTAssertNil(states[bundleA]?.track)
        XCTAssertEqual(states[bundleA]?.isPlaying, true)
    }

    // MARK: - Grace and clearing

    /// A pause within the grace window keeps the last track visible,
    /// flagged not-playing. The monitor marks active continuously while
    /// sound flows, so the last audible moment is the pause point.
    func testRecentPauseWithinGraceKeepsTrackVisible() {
        var catalog = makeCatalog(grace: 4)
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 2)
        catalog.markActivity(bundleIdentifier: bundleA, active: false, at: 2)

        let states = catalog.displayStates(now: 5, activity: [bundleA: false])

        XCTAssertEqual(states[bundleA]?.track, track())
        XCTAssertEqual(states[bundleA]?.isPlaying, false)
    }

    /// Silence beyond the grace window hides the track.
    func testSilenceBeyondGraceHidesTrack() {
        var catalog = makeCatalog(grace: 4)
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 2)
        catalog.markActivity(bundleIdentifier: bundleA, active: false, at: 2)

        let states = catalog.displayStates(now: 7, activity: [bundleA: false])

        XCTAssertNil(states[bundleA]?.track)
    }

    /// A record whose silence outlasts the clear interval is dropped
    /// from display: activity returning later must not resurrect a
    /// stale track.
    func testLongSilenceDropsRecord() {
        var catalog = makeCatalog(grace: 4, clearAfter: 10)
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 2)
        catalog.markActivity(bundleIdentifier: bundleA, active: false, at: 2)

        // Past clear interval: nothing shown...
        let statesAt11 = catalog.displayStates(now: 11, activity: [bundleA: false])
        XCTAssertNil(statesAt11[bundleA]?.track)

        // ...and activity returning later starts empty, not stale.
        let statesAt20 = catalog.displayStates(now: 20, activity: [bundleA: true])
        XCTAssertNil(statesAt20[bundleA]?.track)
        XCTAssertEqual(statesAt20[bundleA]?.isPlaying, true)
    }

    // MARK: - Updates

    /// A later update for the same app replaces the cached track.
    func testLaterUpdateReplacesTrack() {
        var catalog = makeCatalog()
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)

        let next = NowPlayingTrack(title: "Back On 74", artist: "Jungle", album: "Volcano")
        catalog.apply(update: update(track: next, at: 10))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 10)

        let states = catalog.displayStates(now: 10.5, activity: [bundleA: true])
        XCTAssertEqual(states[bundleA]?.track, next)
    }

    /// Identical updates are idempotent - the display state must not
    /// change shape when a source re-reports the same track.
    func testDuplicateUpdatesAreStable() {
        var catalog = makeCatalog()
        catalog.apply(update: update(at: 0))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)
        let first = catalog.displayStates(now: 1, activity: [bundleA: true])

        catalog.apply(update: update(at: 2))
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 2)
        let second = catalog.displayStates(now: 3, activity: [bundleA: true])

        XCTAssertEqual(first, second)
    }

    /// Multiple apps are independent: an update for Spotify must not
    /// leak into Music's row and vice versa.
    func testPerAppIndependence() {
        var catalog = makeCatalog()
        catalog.apply(update: update(bundleID: bundleA, at: 0))
        catalog.apply(
            update: NowPlayingUpdate(
                bundleIdentifier: bundleB,
                track: NowPlayingTrack(title: "Talk To You", artist: "ANOTR"),
                isPlaying: true,
                timestamp: 0
            )
        )
        catalog.markActivity(bundleIdentifier: bundleA, active: true, at: 0)
        catalog.markActivity(bundleIdentifier: bundleB, active: true, at: 0)

        let states = catalog.displayStates(
            now: 1,
            activity: [bundleA: true, bundleB: true]
        )

        XCTAssertEqual(states[bundleA]?.track?.title, "Don't Play")
        XCTAssertEqual(states[bundleB]?.track?.title, "Talk To You")
    }

    // MARK: - Helper JSON parsing (forward-compatible with the
    // MediaRemote helper agent's stream format)

    /// The helper agent line format must parse into an update - this
    /// keeps the V2 helper integration a drop-in.
    func testHelperJSONLineParses() throws {
        let line = """
        {"bundleIdentifier":"com.spotify.client","title":"Don't Play",\
        "artist":"Jungle","album":"Volcano","duration":226.281,\
        "elapsedTime":198.9,"playing":true,"timestamp":123.5}
        """

        let parsed = try NowPlayingUpdate(helperJSONLine: line)

        XCTAssertEqual(parsed.bundleIdentifier, bundleA)
        XCTAssertEqual(parsed.track?.title, "Don't Play")
        XCTAssertEqual(parsed.track?.artist, "Jungle")
        XCTAssertEqual(parsed.track?.album, "Volcano")
        XCTAssertEqual(parsed.track?.duration, 226.281)
        XCTAssertEqual(parsed.isPlaying, true)
        XCTAssertEqual(parsed.timestamp, 123.5)
    }

    /// A helper line with only a title (no artist/album) still parses;
    /// missing fields are optional, not fatal.
    func testHelperJSONLineWithMinimalFieldsParses() throws {
        let line = """
        {"bundleIdentifier":"com.apple.QuickTimePlayerX",\
        "title":"Big Buck Bunny","playing":true,"timestamp":5}
        """

        let parsed = try NowPlayingUpdate(helperJSONLine: line)

        XCTAssertEqual(parsed.track?.title, "Big Buck Bunny")
        XCTAssertNil(parsed.track?.artist)
        XCTAssertNil(parsed.track?.album)
        XCTAssertNil(parsed.track?.duration)
        XCTAssertTrue(parsed.isPlaying)
    }

    /// Malformed helper lines are rejected (the monitor skips them).
    func testMalformedHelperLineThrows() {
        XCTAssertThrowsError(try NowPlayingUpdate(helperJSONLine: "not json"))
        XCTAssertThrowsError(
            try NowPlayingUpdate(helperJSONLine: "{\"title\":42}")
        )
    }
}
