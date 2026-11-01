//
//  NowPlayingModels.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// What a source app reports about its currently loaded media.
///
/// Sources: the AppleScript bridge (Spotify / Music) today, the
/// unsandboxed MediaRemote helper agent later. Metadata never comes from
/// the audio path - process taps carry PCM only.
public struct NowPlayingTrack: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: Double?

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// The line a source row displays: "Artist — Title", or the bare
    /// title when the artist is unknown.
    public var displayLine: String {
        guard let artist, !artist.isEmpty else {
            return title
        }
        return "\(artist) — \(title)"
    }
}

/// One metadata report from a source, addressed to an app by bundle ID.
///
/// `isPlaying` is the *source's* claim about its own player state
/// (authoritative for apps the source owns, like Spotify via AppleScript).
/// App-wide "is it audible right now" remains the tap levels' job.
public struct NowPlayingUpdate: Equatable, Sendable {
    public let bundleIdentifier: String
    public let track: NowPlayingTrack?
    public let isPlaying: Bool
    public let timestamp: TimeInterval

    public init(
        bundleIdentifier: String,
        track: NowPlayingTrack?,
        isPlaying: Bool,
        timestamp: TimeInterval
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.track = track
        self.isPlaying = isPlaying
        self.timestamp = timestamp
    }
}

extension NowPlayingUpdate {
    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case title
        case artist
        case album
        case duration
        case elapsedTime
        case playing
        case timestamp
    }

    /// Parses one line of the MediaRemote helper agent's JSON stream -
    /// the V2 metadata source. Kept here so the helper integration is a
    /// drop-in: the monitor will only ever call this.
    public init(helperJSONLine line: String) throws {
        let data = Data(line.utf8)
        let container = try JSONDecoder().decode(
            HelperPayload.self,
            from: data
        )

        guard let bundleID = container.bundleIdentifier else {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "helper line without bundleIdentifier"
                )
            )
        }

        let track = container.title.map {
            NowPlayingTrack(
                title: $0,
                artist: container.artist,
                album: container.album,
                duration: container.duration ?? container.elapsedTime
            )
        }

        self.init(
            bundleIdentifier: bundleID,
            track: track,
            isPlaying: container.playing ?? false,
            timestamp: container.timestamp ?? 0
        )
    }

    private struct HelperPayload: Decodable {
        let bundleIdentifier: String?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let playing: Bool?
        let timestamp: Double?

        private enum Keys: String, CodingKey {
            case bundleIdentifier
            case title
            case artist
            case album
            case duration
            case elapsedTime
            case playing
            case timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            bundleIdentifier = try container.decodeIfPresent(
                String.self, forKey: .bundleIdentifier
            )
            title = try container.decodeIfPresent(String.self, forKey: .title)
            artist = try container.decodeIfPresent(String.self, forKey: .artist)
            album = try container.decodeIfPresent(String.self, forKey: .album)
            duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            elapsedTime = try container.decodeIfPresent(
                Double.self, forKey: .elapsedTime
            )
            playing = try container.decodeIfPresent(Bool.self, forKey: .playing)
            timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        }
    }
}
