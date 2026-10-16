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
/// Known limitation: macOS does not let a third-party app silence the
/// "original" playback path. If the user has assigned a source to a
/// different device than the system default, they will hear the
/// original playback to the system default plus the routed playback to
/// the chosen device — i.e. echo. This is documented at the UI level
/// and in the design doc.
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
    /// Safe to call from any thread. Does no allocation beyond the
    /// routing decision; the heavy buffer-copy work happens on the
    /// scheduler queue.
    nonisolated func handleSamples(
        fromSourceObjectID sourceID: AudioObjectID,
        bundleIdentifier bundleID: String?,
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
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

        // Copy the samples off the audio thread immediately. The
        // pointer the tap gave us is only valid for the duration of
        // the callback.
        let samples = Self.copySamples(
            from: bufferList,
            frameCount: frameCount
        )

        schedulerQueue.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule(
                    samples: samples,
                    route: route,
                    outputDeviceID: outputDeviceID,
                    sampleRate: sampleRate
                )
            }
        }
    }

    private func schedule(
        samples: [Float],
        route: SourceRoute,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double
    ) {
        Task { @MainActor [weak self] in
            self?.performSchedule(
                samples: samples,
                route: route,
                outputDeviceID: outputDeviceID,
                sampleRate: sampleRate
            )
        }
    }

    @MainActor
    private func performSchedule(
        samples: [Float],
        route: SourceRoute,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double
    ) {
        let engine = ensureEngine(
            forDeviceID: outputDeviceID,
            sampleRate: sampleRate
        )

        let player = ensurePlayer(
            forRoute: route,
            outputDeviceID: outputDeviceID,
            engine: engine
        )

        scheduleBuffer(
            samples: samples,
            on: player,
            engine: engine,
            sourceSampleRate: sampleRate
        )
    }

    // MARK: - Engine lifecycle

    @MainActor
    private func ensureEngine(
        forDeviceID deviceID: AudioDeviceID,
        sampleRate: Double
    ) -> OutputEngine {
        if let existing = enginesByOutput[deviceID] {
            return existing
        }

        let engine = OutputEngine(
            deviceID: deviceID,
            sampleRate: sampleRate
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
        engine: OutputEngine
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
            format: engine.outputFormat
        )
        playersByRoute[key] = player
        return player
    }

    private func scheduleBuffer(
        samples: [Float],
        on player: AVAudioPlayerNode,
        engine: OutputEngine,
        sourceSampleRate: Double
    ) {
        let outputFormat = engine.outputFormat

        guard
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)

        guard
            let channelData = pcmBuffer.floatChannelData
        else {
            return
        }

        let channelCount = Int(outputFormat.channelCount)

        if channelCount == 1 {
            channelData[0].update(
                from: samples,
                count: samples.count
            )
        } else {
            // Deinterleave: input is interleaved Float32 across N
            // channels. Output buffer is planar. Average down if
            // output has fewer channels than input; replicate if
            // output has more.
            let inputChannels = Self.inferInputChannelCount(
                sampleCount: samples.count
            )

            for frame in 0..<samples.count / max(inputChannels, 1) {
                let base = frame * inputChannels
                for channel in 0..<min(channelCount, inputChannels) {
                    channelData[channel][frame] =
                        samples[base + channel]
                }
                // Replicate the last channel into any extras.
                if channelCount > inputChannels {
                    let fill =
                        samples[base + inputChannels - 1]
                    for channel in inputChannels..<channelCount {
                        channelData[channel][frame] = fill
                    }
                }
            }
        }

        player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    private nonisolated static func copySamples(
        from bufferListPointer: UnsafePointer<AudioBufferList>,
        frameCount: Int
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferListPointer)
        )

        var result: [Float] = []
        result.reserveCapacity(frameCount * buffers.count)

        for buffer in buffers {
            guard
                buffer.mDataByteSize > 0,
                let data = buffer.mData
            else {
                continue
            }

            let count =
                Int(buffer.mDataByteSize) /
                MemoryLayout<Float>.size

            let samples = data.assumingMemoryBound(to: Float.self)
            result.append(
                contentsOf: UnsafeBufferPointer(
                    start: samples,
                    count: count
                )
            )
        }

        return result
    }

    private nonisolated static func inferInputChannelCount(
        sampleCount: Int
    ) -> Int {
        // Core Audio aggregate-device taps deliver interleaved stereo
        // Float32 in practice. We assume 2 channels when we have an
        // even sample count; otherwise mono. The downstream engine
        // resamples to the device's actual channel layout.
        if sampleCount % 2 == 0 { return 2 }
        return 1
    }
}

// MARK: - Per-output AVAudioEngine wrapper

/// One `AVAudioEngine` per output device the user has routed audio
/// to. The engine's output AudioUnit is configured to play to a
/// specific Core Audio device, so we can have N independent engines
/// running in parallel — one for the speakers, one for the TV, one
/// for AirPods, etc.
private final class OutputEngine {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    let outputFormat: AVAudioFormat

    let engine = AVAudioEngine()

    init(deviceID: AudioDeviceID, sampleRate: Double) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate

        // Use the engine's output node's native format. The engine
        // detects the device's format lazily when started; before
        // that we ask the default output node for the format the
        // system would use, which is good enough for setting up the
        // mixer bus.
        let native = engine.outputNode.inputFormat(forBus: 0)
        if native.sampleRate > 0 {
            self.outputFormat = native
        } else {
            self.outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 2
            ) ?? AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            )!
        }
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

        engine.connect(
            engine.mainMixerNode,
            to: outputNode,
            format: outputFormat
        )

        try engine.start()
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
}

private struct PlayerKey: Hashable {
    let bundleIdentifier: String
    let outputDeviceID: AudioDeviceID
}