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
    private static let scriptableApps: [String] = [
        "com.spotify.client",
        "com.apple.Music",
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
        for bundleID in Self.scriptableApps {
            guard
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleID
                ).isEmpty
            else {
                continue
            }

            scriptQueue.async { [weak self] in
                let result = Self.queryApp(bundleID: bundleID)
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
    private static func queryApp(bundleID: String) -> ScriptResult? {
        // The caller already checked NSRunningApplication, so the app is
        // running - no System Events probe needed (that would cost a
        // second automation consent prompt for zero information).
        // `application id` with the bundle ID avoids name-based app
        // lookup issues.
        let query = """
        tell application id "\(bundleID)"
            set playerState to player state as text
            if playerState is "stopped" then return "stopped"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            return trackName & (ASCII character 31) & trackArtist & (ASCII character 31) & trackAlbum & (ASCII character 31) & playerState
        end tell
        """

        guard let output = runAppleScript(query, forBundleID: bundleID) else {
            return nil
        }

        guard output != "stopped" else {
            return ScriptResult(track: nil, isPlaying: false)
        }

        let parts = output.components(separatedBy: "\u{1F}")
        guard parts.count >= 4 else {
            nowPlayingLog.error(
                "unexpected script output from \(bundleID, privacy: .public): '\(output.prefix(120), privacy: .public)'"
            )
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

    /// Runs an AppleScript via `/usr/bin/osascript`. NSAppleScript is
    /// not thread-safe and silently fails off the main thread; a
    /// subprocess has no threading constraints and reports errors
    /// reliably.
    private static func runAppleScript(
        _ source: String,
        forBundleID bundleID: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            nowPlayingLog.error(
                "osascript spawn failed for \(bundleID, privacy: .public): \(error)"
            )
            return nil
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "no stderr"
            nowPlayingLog.error(
                "osascript failed for \(bundleID, privacy: .public), status \(process.terminationStatus): \(message.prefix(300), privacy: .public)"
            )
            return nil
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
