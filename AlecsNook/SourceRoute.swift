//
//  SourceRoute.swift
//  AlecsNook
//
//  Created by Alec Candidato on 8/7/26.
//

import CoreAudio
import Foundation

/// A user's choice of where a specific source's audio should be played.
///
/// One entry per (source, output) pair. Persisted in `RouteStore` and
/// consulted by `AudioRouter` whenever a buffer from the source arrives.
///
/// `outputDeviceID` is the Core Audio `AudioDeviceID` of the target
/// device. `nil` means "follow system default" — the source plays to
/// whatever the system default output device is at the moment, no
/// replay through `AudioRouter`. That is the safe default for any source
/// the user has not explicitly routed.
struct SourceRoute: Codable, Hashable {
    /// Stable identifier of the source process. We use the
    /// `AudioObjectID` of the audio process object Core Audio assigns
    /// at process-launch time — it survives restart of the source app
    /// as long as the OS hasn't recycled the ID, which is good enough
    /// for in-session routing.
    let sourceObjectID: AudioObjectID

    /// Bundle identifier, when known. Persisted alongside the object
    /// ID so a route can survive a source-process restart even if the
    /// `AudioObjectID` has been recycled.
    let bundleIdentifier: String?

    /// Friendly application name at the time the route was created.
    /// Used for display in the route picker.
    let applicationName: String

    /// `nil` means "system default"; otherwise a specific Core Audio
    /// `AudioDeviceID` of the output device to play this source to.
    var outputDeviceID: AudioDeviceID?

    /// Whether the audio should also be replayed by `AudioRouter` to
    /// the chosen device. `false` is the safe default (no echo) and
    /// means the source plays to the system default as Core Audio
    /// would normally route it.
    var enabled: Bool

    init(
        sourceObjectID: AudioObjectID,
        bundleIdentifier: String?,
        applicationName: String,
        outputDeviceID: AudioDeviceID? = nil,
        enabled: Bool = false
    ) {
        self.sourceObjectID = sourceObjectID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.outputDeviceID = outputDeviceID
        self.enabled = enabled
    }

    /// Stable key used to look up routes in the in-memory map and to
    /// persist them across launches. Prefer `bundleIdentifier` when
    /// available so the route survives a source-process restart;
    /// otherwise fall back to the audio-process `AudioObjectID`.
    var stableKey: String {
        bundleIdentifier ?? "audio-object-\(sourceObjectID)"
    }
}