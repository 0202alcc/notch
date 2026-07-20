//
//  AudioMuteMonitor.swift
//  MyNook
//
//  Created by Alec Candidato on 7/19/26.
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation

@MainActor
final class AudioMuteMonitor: ObservableObject {
    static let shared = AudioMuteMonitor()

    @Published private(set) var isSpeakerMuted = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isMicrophoneInUse = false

    private var timer: Timer?

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
        isMicrophoneInUse = Self.readMicrophoneUsage()
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

    private static func readMicrophoneUsage() -> Bool {
        let processes = audioProcessObjects()

        for processID in processes {
            if processIsUsingInput(processID) {
                return true
            }
        }

        return false
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectHasProperty(systemObject, &address) else {
            return []
        }

        var dataSize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size

        guard count > 0 else {
            return []
        }

        var processObjects = Array(
            repeating: AudioObjectID(0),
            count: count
        )

        let readStatus = processObjects.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }

        guard readStatus == noErr else {
            return []
        }

        return processObjects
    }

    private static func processIsUsingInput(
        _ processObject: AudioObjectID
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObject, &address) else {
            return false
        }

        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &dataSize,
            &isRunning
        )

        guard status == noErr else {
            return false
        }

        return isRunning != 0
    }
    
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
