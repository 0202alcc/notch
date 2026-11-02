//
//  SourceRoute.swift
//  NookKit
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
public struct SourceRoute: Codable, Hashable {
    /// Stable identifier of the source process. We use the
    /// `AudioObjectID` of the audio process object Core Audio assigns
    /// at process-launch time — it survives restart of the source app
    /// as long as the OS hasn't recycled the ID, which is good enough
    /// for in-session routing.
    public var sourceObjectID: AudioObjectID

    /// Bundle identifier, when known. Persisted alongside the object
    /// ID so a route can survive a source-process restart even if the
    /// `AudioObjectID` has been recycled.
    public let bundleIdentifier: String?

    /// Friendly application name at the time the route was created.
    /// Used for display in the route picker.
    public let applicationName: String

    /// `nil` means "system default"; otherwise a specific Core Audio
    /// `AudioDeviceID` of the output device to play this source to.
    ///
    /// This is a *cached* handle: `AudioDeviceID`s are runtime-only and
    /// go stale when a device reconnects or coreaudiod restarts. The
    /// durable identity is `outputDeviceUID`; the ID is re-resolved
    /// from the UID at replay time.
    public var outputDeviceID: AudioDeviceID?

    /// Durable identity of the target device (Core Audio device UID).
    /// Survives reconnection, reboot, and ID recycling; `nil` for
    /// routes written before UID tracking existed.
    public var outputDeviceUID: String?

    /// Whether the audio should also be replayed by `AudioRouter` to
    /// the chosen device. `false` is the safe default (no echo) and
    /// means the source plays to the system default as Core Audio
    /// would normally route it.
    public var enabled: Bool

    /// Replay gain for this source (0...1, 1 = full). Applied to the
    /// replay player, which is the only audible path while the route is
    /// enabled (the tap mutes the original), so this is the effective
    /// per-source volume.
    public var volume: Double

    /// Per-band EQ gains in dB (-12...+12; 0 = flat), applied by the
    /// replay engine's per-route filter chain.
    public var eqLowDB: Double
    public var eqMidDB: Double
    public var eqHighDB: Double

    public init(
        sourceObjectID: AudioObjectID,
        bundleIdentifier: String?,
        applicationName: String,
        outputDeviceID: AudioDeviceID? = nil,
        outputDeviceUID: String? = nil,
        enabled: Bool = false,
        volume: Double = 1,
        eqLowDB: Double = 0,
        eqMidDB: Double = 0,
        eqHighDB: Double = 0
    ) {
        self.sourceObjectID = sourceObjectID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.outputDeviceID = outputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.enabled = enabled
        self.volume = volume
        self.eqLowDB = eqLowDB
        self.eqMidDB = eqMidDB
        self.eqHighDB = eqHighDB
    }

    // Custom Codable so records written before `outputDeviceUID` / `volume`
    // existed decode cleanly (missing keys → defaults) instead of failing
    // the whole store back to defaults.
    private enum CodingKeys: String, CodingKey {
        case sourceObjectID
        case bundleIdentifier
        case applicationName
        case outputDeviceID
        case outputDeviceUID
        case enabled
        case volume
        case eqLowDB
        case eqMidDB
        case eqHighDB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceObjectID = try container.decode(AudioObjectID.self, forKey: .sourceObjectID)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        outputDeviceID = try container.decodeIfPresent(AudioDeviceID.self, forKey: .outputDeviceID)
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        eqLowDB = try container.decodeIfPresent(Double.self, forKey: .eqLowDB) ?? 0
        eqMidDB = try container.decodeIfPresent(Double.self, forKey: .eqMidDB) ?? 0
        eqHighDB = try container.decodeIfPresent(Double.self, forKey: .eqHighDB) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceObjectID, forKey: .sourceObjectID)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(applicationName, forKey: .applicationName)
        try container.encodeIfPresent(outputDeviceID, forKey: .outputDeviceID)
        try container.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(volume, forKey: .volume)
        try container.encode(eqLowDB, forKey: .eqLowDB)
        try container.encode(eqMidDB, forKey: .eqMidDB)
        try container.encode(eqHighDB, forKey: .eqHighDB)
    }

    /// Stable key used to look up routes in the in-memory map and to
    /// persist them across launches. Prefer `bundleIdentifier` when
    /// available so the route survives a source-process restart;
    /// otherwise fall back to the audio-process `AudioObjectID`.
    public var stableKey: String {
        bundleIdentifier ?? "audio-object-\(sourceObjectID)"
    }
}