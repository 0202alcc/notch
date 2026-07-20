//
//  ProcessAudioTap.swift
//  AlecsNook
//
//  Created by Alec Candidato on 7/19/26.
//

import CoreAudio
import Foundation

enum ProcessAudioTapError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case missingTap
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            return "\(operation) failed with Core Audio status \(status)."

        case .missingTap:
            return "Core Audio did not create the requested process tap."

        case .unsupportedFormat:
            return "The process tap did not provide Float32 PCM audio."
        }
    }
}

/// Captures the outgoing audio for one Core Audio process object.
///
/// This class deliberately does very little work inside the real-time audio
/// callback. It calculates one RMS value and dispatches that value elsewhere.
final class ProcessAudioTap: @unchecked Sendable {
    typealias LevelHandler = @Sendable (Float) -> Void

    let processObjectIDs: [AudioObjectID]

    private let levelHandler: LevelHandler
    private let callbackQueue: DispatchQueue

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private let lifecycleLock = NSLock()
    private var started = false

    init(
        processObjectIDs: [AudioObjectID],
        levelHandler: @escaping LevelHandler
    ) {
        self.processObjectIDs = processObjectIDs
        self.levelHandler = levelHandler

        let identifier = processObjectIDs
            .map(String.init)
            .joined(separator: "-")

        self.callbackQueue = DispatchQueue(
            label: "org.aleccandidato.MyNook.audio-tap.\(identifier)",
            qos: .userInteractive
        )
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !started else {
            return
        }

        do {
            try createProcessTap()
            try createAggregateDevice()
            try createIOProc()
            try startIO()

            started = true
        } catch {
            tearDownWithoutLock()
            throw error
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        tearDownWithoutLock()
    }

    // MARK: - Tap creation

    private func createProcessTap() throws {
        let description = CATapDescription(
            stereoMixdownOfProcesses: processObjectIDs
        )

        description.name = "MyNook \(processObjectIDs.count)-Process Mix"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)

        let status = AudioHardwareCreateProcessTap(
            description,
            &newTapID
        )

        try check(status, operation: "Create process tap")

        guard newTapID != kAudioObjectUnknown else {
            throw ProcessAudioTapError.missingTap
        }

        tapID = newTapID
    }

    private func createAggregateDevice() throws {
        let tapUID = try readTapUID(tapID)

        let aggregateUID =
            "org.aleccandidato.MyNook.tap.\(UUID().uuidString)"

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:
                "MyNook Process Meter",

            kAudioAggregateDeviceUIDKey:
                aggregateUID,

            kAudioAggregateDeviceIsPrivateKey:
                true,

            kAudioAggregateDeviceIsStackedKey:
                false,

            kAudioAggregateDeviceTapAutoStartKey:
                true,

            kAudioAggregateDeviceSubDeviceListKey:
                [],

            kAudioAggregateDeviceTapListKey:
                [tapEntry]
        ]

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)

        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &newDeviceID
        )

        try check(status, operation: "Create aggregate device")

        aggregateDeviceID = newDeviceID
    }

    private func readTapUID(
        _ tapID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                $0
            )
        }

        try check(status, operation: "Read tap UID")

        return value as String
    }

    // MARK: - IO

    private func createIOProc() throws {
        var newIOProcID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            aggregateDeviceID,
            callbackQueue
        ) { [weak self] _, inputData, _, _, _ in
            guard let self else {
                return
            }

            let level = Self.calculateRMS(
                from: inputData
            )

            self.levelHandler(level)
        }

        try check(status, operation: "Create IO callback")

        ioProcID = newIOProcID
    }

    private func startIO() throws {
        let status = AudioDeviceStart(
            aggregateDeviceID,
            ioProcID
        )

        try check(status, operation: "Start aggregate-device IO")
    }

    // MARK: - Meter calculation

    private static func calculateRMS(
        from bufferListPointer: UnsafePointer<AudioBufferList>
    ) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(
                mutating: bufferListPointer
            )
        )

        var sumOfSquares: Double = 0
        var sampleCount = 0

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

            guard count > 0 else {
                continue
            }

            let samples = data.assumingMemoryBound(
                to: Float.self
            )

            for index in 0..<count {
                let sample = samples[index]

                guard sample.isFinite else {
                    continue
                }

                let value = Double(sample)
                sumOfSquares += value * value
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return 0
        }

        let rms = sqrt(
            sumOfSquares / Double(sampleCount)
        )

        // Convert the approximately useful range from -60 dB...0 dB
        // into a visual 0...1 range.
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = (decibels + 60) / 60

        return Float(min(max(normalized, 0), 1))
    }

    // MARK: - Cleanup

    private func tearDownWithoutLock() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(
                    aggregateDeviceID,
                    ioProcID
                )

                AudioDeviceDestroyIOProcID(
                    aggregateDeviceID,
                    ioProcID
                )
            }

            AudioHardwareDestroyAggregateDevice(
                aggregateDeviceID
            )
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        ioProcID = nil
        aggregateDeviceID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        started = false
    }

    private func check(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw ProcessAudioTapError.coreAudio(
                operation: operation,
                status: status
            )
        }
    }
}
