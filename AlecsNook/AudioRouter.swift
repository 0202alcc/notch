//
//  AudioRouter.swift
//  AlecsNook
//
//  Created by Alec Candidato on 8/7/26.
//

import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation
import NookKit
import os

/// Receives audio buffers from per-source `ProcessAudioTap`s and
/// replays them to the user's chosen output device for each source.
///
/// One `AVAudioEngine` is created per distinct output device the user
/// has routed any source to. Each engine has its own clock so devices
/// stay in sync internally; cross-device drift is handled implicitly
/// because each engine is driven by the device's own hardware clock.
///
/// The audio thread consults `RouteStore` (lock-free via an
/// `OSAllocatedUnfairLock` snapshot) to decide whether a buffer should
/// be replayed at all, and if so, to which engine. Buffer scheduling
/// into the target engine is dispatched onto the engine's dedicated
/// dispatch queue to keep the audio render thread off the main actor.
///
/// Known limitation (superseded): the tap's `mutedWhenTapped` behavior
/// silences the original hardware path for the duration of read activity,
/// so a routed source is heard only on its chosen device while
/// `AudioRouter` is consuming the tap. If the router is not consuming
/// (no enabled route), the tap runs `.unmuted` and macOS playback is
/// untouched.
final class AudioRouter {
    nonisolated(unsafe) static let shared = AudioRouter()

    /// Per-output engines, keyed by the Core Audio `AudioDeviceID` of
    /// the target device. Created lazily on first use, torn down when
    /// the device disappears.
    private var enginesByOutput: [AudioDeviceID: OutputEngine] = [:]

    /// Per-(source, output) player nodes. Each `(bundleID, deviceID)`
    /// pair has at most one player.
    private var playersByRoute:
        [PlayerKey: AVAudioPlayerNode] = [:]

    /// Serial dispatch queue used to schedule buffers into engines.
    /// AVAudioEngine is not safe to mutate from arbitrary threads; all
    /// scheduling for a given engine must happen on a single queue.
    private let schedulerQueue = DispatchQueue(
        label: "AlecsNook.AudioRouter.scheduler",
        qos: .userInteractive
    )

    private init() {}

    // MARK: - Audio-thread entry point

    /// Called from the `samplesHandler` closure installed on each
    /// per-source `ProcessAudioTap`. Looks up the route and forwards
    /// the buffer to the correct engine.
    ///
    /// Safe to call from any thread. Frame and channel counts are
    /// derived from the buffer list itself (interleaved and planar
    /// layouts both supported via `AudioBufferListMath`); the heavy
    /// buffer-copy work happens on the scheduler queue.
    nonisolated func handleSamples(
        fromSourceObjectID sourceID: AudioObjectID,
        bundleIdentifier bundleID: String?,
        bufferList: UnsafePointer<AudioBufferList>,
        sampleRate: Double
    ) {
        let store = RouteStore.shared

        guard store.isRoutingEnabled else { return }

        let route = store.route(forSourceObjectID: sourceID)
            ?? store.route(forBundleIdentifier: bundleID)

        guard
            let route,
            route.enabled,
            let outputDeviceID = route.outputDeviceID
        else {
            return
        }

        // Copy the samples off the audio thread immediately, normalized
        // to planar. The pointer the tap gave us is only valid for the
        // duration of the callback.
        let (channels, frameCount) = AudioBufferListMath.planarChannels(
            of: bufferList
        )
        guard frameCount > 0, !channels.isEmpty else { return }

        schedulerQueue.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule(
                    channels: channels,
                    frameCount: frameCount,
                    route: route,
                    outputDeviceID: outputDeviceID,
                    sampleRate: sampleRate
                )
            }
        }
    }

    private func schedule(
        channels: [[Float]],
        frameCount: Int,
        route: SourceRoute,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double
    ) {
        Task { @MainActor [weak self] in
            self?.performSchedule(
                channels: channels,
                frameCount: frameCount,
                route: route,
                outputDeviceID: outputDeviceID,
                sampleRate: sampleRate
            )
        }
    }

    @MainActor
    private func performSchedule(
        channels: [[Float]],
        frameCount: Int,
        route: SourceRoute,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double
    ) {
        let engine = ensureEngine(
            forDeviceID: outputDeviceID
        )

        let player = ensurePlayer(
            forRoute: route,
            outputDeviceID: outputDeviceID,
            engine: engine,
            sourceSampleRate: sampleRate,
            sourceChannels: channels.count
        )

        scheduleBuffer(
            channels: channels,
            frameCount: frameCount,
            on: player,
            sourceSampleRate: sampleRate
        )
    }

    // MARK: - Engine lifecycle

    @MainActor
    private func ensureEngine(
        forDeviceID deviceID: AudioDeviceID
    ) -> OutputEngine {
        if let existing = enginesByOutput[deviceID] {
            return existing
        }

        let engine = OutputEngine(
            deviceID: deviceID
        )

        do {
            try engine.start()
            enginesByOutput[deviceID] = engine
            return engine
        } catch {
            NSLog(
                "AudioRouter: failed to start engine for device "
                + "\(deviceID): \(error)"
            )
            return engine
        }
    }

    @MainActor
    private func ensurePlayer(
        forRoute route: SourceRoute,
        outputDeviceID: AudioDeviceID,
        engine: OutputEngine,
        sourceSampleRate: Double,
        sourceChannels: Int
    ) -> AVAudioPlayerNode {
        let key = PlayerKey(
            bundleIdentifier: route.bundleIdentifier
                ?? "audio-object-\(route.sourceObjectID)",
            outputDeviceID: outputDeviceID
        )

        if let existing = playersByRoute[key] {
            return existing
        }

        let player = AVAudioPlayerNode()
        engine.attachAndConnect(
            player: player,
            format: Self.sourceFormat(
                sampleRate: sourceSampleRate,
                channels: sourceChannels
            )
        )
        playersByRoute[key] = player
        return player
    }

    /// The playback format of a tapped source: non-interleaved Float32
    /// at the tap's sample rate. The engine's mixer resamples this to
    /// the output device's native format.
    private nonisolated static func sourceFormat(
        sampleRate: Double,
        channels: Int
    ) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(max(channels, 1)),
            interleaved: false
        ) ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
    }

    private func scheduleBuffer(
        channels: [[Float]],
        frameCount: Int,
        on player: AVAudioPlayerNode,
        sourceSampleRate: Double
    ) {
        let outputChannelCount = max(channels.count, 1)

        let format = Self.sourceFormat(
            sampleRate: sourceSampleRate,
            channels: outputChannelCount
        )

        guard
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channelData = pcmBuffer.floatChannelData
        else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Planar fill. A mono source feeding a stereo output is
        // duplicated; a stereo source feeding a mono output is averaged.
        if outputChannelCount < channels.count {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in channels {
                    sum += channel[frame]
                }
                channelData[0][frame] = sum / Float(channels.count)
            }
        } else {
            for (outputChannel, sourceChannel) in channels.enumerated() {
                channelData[outputChannel].update(
                    from: sourceChannel,
                    count: frameCount
                )
            }
            for outputChannel in channels.count..<outputChannelCount {
                channelData[outputChannel].update(
                    from: channels[channels.count - 1],
                    count: frameCount
                )
            }
        }

        player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Teardown

    /// Drop the player (and, when it is the last one, the whole engine)
    /// for a route the user has disabled or reset to "system default".
    @MainActor
    func teardownRoute(forBundleIdentifier bundleID: String) {
        let keys = playersByRoute.keys.filter { $0.bundleIdentifier == bundleID }
        for key in keys {
            guard let player = playersByRoute.removeValue(forKey: key) else {
                continue
            }
            player.stop()
            if let engine = enginesByOutput[key.outputDeviceID] {
                engine.detach(player: player)
            }
        }

        // Tear down engines that no longer have any player.
        for deviceID in enginesByOutput.keys {
            let stillUsed = playersByRoute.contains {
                $0.key.outputDeviceID == deviceID
            }
            if !stillUsed {
                if let engine = enginesByOutput.removeValue(forKey: deviceID) {
                    engine.stop()
                }
            }
        }
    }

    /// Stops and forgets every engine and player - used when global
    /// routing is switched off.
    @MainActor
    func teardownAll() {
        for (_, player) in playersByRoute {
            player.stop()
        }
        playersByRoute.removeAll()
        for (_, engine) in enginesByOutput {
            engine.stop()
        }
        enginesByOutput.removeAll()
    }
}

// MARK: - Per-output AVAudioEngine wrapper

/// One `AVAudioEngine` per output device the user has routed audio
/// to. The engine's output AudioUnit is configured to play to a
/// specific Core Audio device, so we can have N independent engines
/// running in parallel — one for the speakers, one for the TV, one
/// for AirPods, etc.
///
/// Source-format players are attached per route; the mixer resamples
/// each player's stream to the device's native format, so sources
/// running at a different rate than the device stay correct.
private final class OutputEngine {
    let deviceID: AudioDeviceID

    let engine = AVAudioEngine()

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func start() throws {
        let outputNode = engine.outputNode

        // Pin the engine's output to the user-selected device via the
        // underlying AudioUnit's `kAudioOutputUnitProperty_CurrentDevice`.
        // On macOS this is the supported way to direct an
        // `AVAudioEngine` to a non-default output device.
        if let audioUnit = outputNode.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                AudioUnitPropertyID(
                    kAudioOutputUnitProperty_CurrentDevice
                ),
                AudioUnitScope(kAudioUnitScope_Global),
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                NSLog(
                    "OutputEngine: AudioUnitSetProperty failed "
                    + "(\(status)) for device \(deviceID)"
                )
            }
        }

        // `nil` format: the engine picks the output device's native
        // format for the mixer→output leg.
        engine.connect(
            engine.mainMixerNode,
            to: outputNode,
            format: nil
        )

        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func attachAndConnect(
        player: AVAudioPlayerNode,
        format: AVAudioFormat
    ) {
        engine.attach(player)
        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: format
        )
    }

    func detach(player: AVAudioPlayerNode) {
        engine.detach(player)
    }
}

private struct PlayerKey: Hashable {
    let bundleIdentifier: String
    let outputDeviceID: AudioDeviceID
}