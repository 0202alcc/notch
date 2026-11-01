//
//  NowPlayingMonitor.swift
//  AlecsNook
//
//  Created by Alec Candidato on 11/1/26.
//

import AppKit
import Foundation
import NookKit
import os

/// Bridges per-app metadata sources into the `NowPlayingCatalogState`
/// and publishes per-row display state.
///
/// V1 sources: the AppleScript bridge for Spotify and Music (per-app,
/// exact, no helper install). V2 (planned): the unsandboxed MediaRemote
/// helper agent for generic apps - its JSON lines parse directly into
/// `NowPlayingUpdate`, so it will be a drop-in feed.
///
/// Activity (which apps are actually audible) comes from the
/// `ApplicationAudioMonitor` tap levels - the waveform's ground truth.
private let nowPlayingLog = Logger(
    subsystem: "io.github.0202alcc.AlecsNook",
    category: "NowPlayingMonitor"
)

@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    /// Bundle ID → what the row should display right now.
    @Published private(set) var states: [String: NowPlayingDisplayState] = [:]

    private var catalog = NowPlayingCatalogState()
    private var pollTimer: Timer?
    private var pollInFlight = false

    /// Apps with an AppleScript dictionary we can query directly.
    private static let scriptableApps: [(bundleID: String, app: String)] = [
        (bundleID: "com.spotify.client", app: "Spotify"),
        (bundleID: "com.apple.Music", app: "Music"),
    ]

    private let scriptQueue = DispatchQueue(
        label: "org.aleccandidato.MyNook.nowplaying-scripts",
        qos: .utility
    )

    private init() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Display line for a row, or nil when nothing is known.
    func line(forBundleIdentifier bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return states[bundleID]?.track?.displayLine
    }

    // MARK: - Poll cycle

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        // 1. Tap-level activity: the ground truth for "audible now".
        for (bundleID, audible) in ApplicationAudioMonitor.shared
            .audibleBundleIdentifiers()
        {
            catalog.markActivity(
                bundleIdentifier: bundleID,
                active: audible,
                at: now()
            )
        }

        // 2. Scriptable apps: query their player state + current track
        //    off the main thread.
        for app in Self.scriptableApps {
            guard
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: app.bundleID
                ).isEmpty
            else {
                continue
            }

            let bundleID = app.bundleID
            let appName = app.app
            scriptQueue.async { [weak self] in
                let result = Self.queryApp(appName: appName)
                Task { @MainActor in
                    self?.applyScriptResult(result, bundleID: bundleID)
                }
            }
        }

        publishStates()
    }

    private func applyScriptResult(
        _ result: ScriptResult?,
        bundleID: String
    ) {
        guard let result else { return }

        catalog.apply(
            update: NowPlayingUpdate(
                bundleIdentifier: bundleID,
                track: result.track,
                isPlaying: result.isPlaying,
                timestamp: now()
            )
        )
        // The source's own player state is authoritative activity for
        // the app it belongs to.
        catalog.markActivity(
            bundleIdentifier: bundleID,
            active: result.isPlaying,
            at: now()
        )
        publishStates()
    }

    private func publishStates() {
        states = catalog.displayStates(
            now: now(),
            activity: ApplicationAudioMonitor.shared
                .audibleBundleIdentifiers()
        )
    }

    private func now() -> TimeInterval {
        CFAbsoluteTimeGetCurrent()
    }

    // MARK: - AppleScript bridge

    private struct ScriptResult {
        let track: NowPlayingTrack?
        let isPlaying: Bool
    }

    /// Runs the per-app query AppleScript. Blocking and slow (tens of
    /// ms) - call only from `scriptQueue`.
    ///
    /// Returns nil when the app is not running, has no track, or the
    /// automation was denied. First contact triggers macOS's
    /// "AlecsNook wants to control <app>" consent prompt - that is
    /// expected and one-time.
    private static func queryApp(appName: String) -> ScriptResult? {
        // The caller already checked NSRunningApplication, so the app is
        // running - no System Events probe needed (that would cost a
        // second automation consent prompt for zero information).
        let query = """
        tell application "\(appName)"
            set playerState to player state as text
            if playerState is "stopped" then return "stopped"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            return trackName & (ASCII character 31) & trackArtist & (ASCII character 31) & trackAlbum & (ASCII character 31) & playerState
        end tell
        """

        guard let output = runSimpleAppleScript(query) else {
            return nil
        }

        guard output != "stopped" else {
            return ScriptResult(track: nil, isPlaying: false)
        }

        let parts = output.components(separatedBy: "\u{1F}")
        guard parts.count >= 4 else {
            return nil
        }

        let track = NowPlayingTrack(
            title: parts[0],
            artist: parts[1].isEmpty ? nil : parts[1],
            album: parts[2].isEmpty ? nil : parts[2]
        )
        return ScriptResult(
            track: track,
            isPlaying: parts[3] == "playing"
        )
    }

    private static func runSimpleAppleScript(
        _ source: String
    ) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let output = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            nowPlayingLog.error(
                "apple script failed: \(errorInfo, privacy: .public)"
            )
            return nil
        }
        return output?.stringValue
    }
}
