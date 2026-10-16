//
//  AudioMuteMonitor.swift
//  MyNook
//
//  Created by Alec Candidato on 7/19/26.
//

import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

/// Captures the peak amplitude of the default input device so the
/// microphone-in-use indicator can reflect actual mic activity rather than
/// the unreliable `kAudioProcessPropertyIsRunningInput` per-process boolean.
///
/// When you play music, several Apple audio daemons (and sometimes the music
/// app itself) report `isRunningInput == true` continuously even though the
/// microphone is silent - opening an input stream is not the same as
/// capturing real audio. The definitive signal is the input device's actual
/// audio level: real recording produces a sustained level above the noise
/// floor, while a silent open stream does not.
final class InputLevelMeter {
    private let peak = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let engine = AVAudioEngine()
    private let meterQueue = DispatchQueue(
        label: "AlecsNook.InputLevelMeter",
        qos: .userInitiated
    )

    /// Re-arm listener token for the active input device's
    /// `kAudioDevicePropertyDeviceIsAlive`. When the default input
    /// device disappears (USB headset unplugged, AirPods disconnect),
    /// the HAL fires this and we re-bind to whichever input device is
    /// now current — without it, the engine keeps its stale input node
    /// and AVAudio posts `-10877` (`kIOReturnNotAttached`) on every
    /// subsequent render cycle.
    private var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var isAliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var isAliveListenerObjectID: AudioObjectID = kAudioObjectUnknown

    /// Peak amplitude of the most recent render block (linear, 0...1).
    /// Thread-safe to read from any context.
    var peakValue: Float {
        peak.withLock { $0 }
    }

    init() {
        arm()
    }

    deinit {
        detachIsAliveListener()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Install the input tap and start the engine. Safe to call
    /// repeatedly — the engine is stopped first so successive
    /// configurations don't stack taps on top of each other.
    private func arm() {
        meterQueue.async { [weak self] in
            guard let self else { return }

            self.detachIsAliveListener()
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)

            let inputNode = self.engine.inputNode
            let format = inputNode.inputFormat(forBus: 0)

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format
            ) { [weak self] buffer, _ in
                self?.process(buffer: buffer)
            }

            do {
                try self.engine.start()
            } catch {
                NSLog(
                    "InputLevelMeter failed to start: \(error)"
                )
            }

            // After the engine is up, ask the system which device it
            // bound to and subscribe to that device's
            // `kAudioDevicePropertyDeviceIsAlive` so we re-arm if it
            // disappears.
            self.attachIsAliveListener(forCurrentInputNode: inputNode)
        }
    }

    private func attachIsAliveListener(
        forCurrentInputNode inputNode: AVAudioInputNode
    ) {
        // `AVAudioInputNode` doesn't expose the underlying
        // `AudioDeviceID` on macOS. Use the default-input-device
        // hardware property — that's the device the engine bound to
        // when it started.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return
        }

        inputDeviceID = deviceID

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.arm()
        }

        let addStatus = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &aliveAddress,
            meterQueue,
            block
        )

        if addStatus == noErr {
            isAliveListenerBlock = block
            isAliveListenerObjectID = deviceID
        }
    }

    private func detachIsAliveListener() {
        guard
            isAliveListenerObjectID != kAudioObjectUnknown,
            let block = isAliveListenerBlock
        else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            isAliveListenerObjectID,
            &address,
            meterQueue,
            block
        )

        isAliveListenerBlock = nil
        isAliveListenerObjectID = kAudioObjectUnknown
        inputDeviceID = kAudioObjectUnknown
    }

    /// Audio-thread callback. Iterates the samples of the supplied buffer
    /// and stores the largest absolute value as the latest peak.
    private func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var localPeak: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let value = abs(samples[frame])
                if value > localPeak {
                    localPeak = value
                }
            }
        }

        peak.withLock { state in
            state = localPeak
        }
    }
}

@MainActor
final class AudioMuteMonitor: ObservableObject {
    static let shared = AudioMuteMonitor()

    @Published private(set) var isSpeakerMuted = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isMicrophoneInUse = false

    private var timer: Timer?

    // Real input audio level, in linear amplitude (0...1). Drives the mic
    // indicator in place of the unreliable Core Audio per-process boolean.
    private let inputLevelMeter = InputLevelMeter()

    // Hysteresis counters for the mic-in-use indicator so brief excursions
    // above / below the noise floor do not flicker the icon.
    private var micInUseTrueStreak: Int = 0
    private var micInUseFalseStreak: Int = 0
    private let micInUseDebounce: Int = 2

    /// Peak amplitude that counts as "real" mic activity. Below this we treat
    /// the mic as idle even if a process technically has the input stream
    /// open (system daemons, the music app holding input for a voice feature,
    /// etc.). Roughly -46 dBFS - well above electrical noise floor but
    /// below typical speech.
    private let micInUseThreshold: Float = 0.005

    private init() {
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isSpeakerMuted = Self.readOutputMuteState()
        isMicrophoneMuted = Self.readInputMuteState()
        isMicrophoneInUse = updateMicrophoneInUse(
            peak: inputLevelMeter.peakValue
        )
    }

    private func updateMicrophoneInUse(peak: Float) -> Bool {
        let raw = peak >= micInUseThreshold

        if raw {
            micInUseTrueStreak += 1
            micInUseFalseStreak = 0
        } else {
            micInUseFalseStreak += 1
            micInUseTrueStreak = 0
        }

        // Hold the current value while the raw signal is unstable so a
        // single-frame excursion does not reach SwiftUI.
        if raw {
            if micInUseTrueStreak >= micInUseDebounce {
                return true
            }
        } else {
            if micInUseFalseStreak >= micInUseDebounce {
                return false
            }
        }

        return isMicrophoneInUse
    }

    // MARK: - Output

    private static func readOutputMuteState() -> Bool {
        guard let deviceID = defaultDevice(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) else {
            return false
        }

        // First try the device's actual mute property.
        if let muted = readBooleanProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        ) {
            return muted
        }

        // Some devices have no separate mute property.
        // In that case, treat zero output volume as muted.
        if let volume = readVolume(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        ) {
            return volume <= 0.001
        }

        return false
    }

    // MARK: - Input

    private static func readInputMuteState() -> Bool {
        guard let deviceID = defaultDevice(
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) else {
            // No available input device means there is effectively
            // no usable microphone.
            return true
        }

        // External audio interfaces may expose an input mute property.
        if let muted = readBooleanProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput
        ) {
            return muted
        }

        // Most built-in microphones do not expose a global mute switch.
        // Treat zero input gain as muted when gain is readable.
        if let volume = readVolume(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        ) {
            return volume <= 0.001
        }

        return false
    }

    // MARK: - Microphone usage
    //
    // The previous per-process boolean approach (`kAudioProcessPropertyIsRunningInput`)
    // was unreliable: music playback, system daemons, and various Apple audio
    // subsystems hold the input stream open continuously and report
    // `isRunningInput == true` even though the microphone is silent. The
    // definitive signal is the input device's actual audio level, which is
    // captured by `InputLevelMeter` above and gated through
    // `updateMicrophoneInUse(peak:)` in `refresh()`.
    // MARK: - Core Audio helpers

    private static func defaultDevice(
        selector: AudioObjectPropertySelector
    ) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private static func readBooleanProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value != 0
    }

    private static func readVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        // Try the main device volume first.
        if let mainVolume = readVolume(
            deviceID: deviceID,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) {
            return mainVolume
        }

        // Some devices expose volume only through individual channels.
        let left = readVolume(
            deviceID: deviceID,
            scope: scope,
            element: 1
        )

        let right = readVolume(
            deviceID: deviceID,
            scope: scope,
            element: 2
        )

        switch (left, right) {
        case let (left?, right?):
            return max(left, right)

        case let (left?, nil):
            return left

        case let (nil, right?):
            return right

        case (nil, nil):
            return nil
        }
    }

    private static func readVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value
    }
}
