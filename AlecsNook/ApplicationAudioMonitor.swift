//
//  ApplicationAudioMonitor.swift
//  AlecsNook
//
//  Created by Alec Candidato on 7/19/26.
//


import AppKit
import Combine
import CoreAudio
import Foundation

// MARK: - Immutable discovery result

/// A snapshot returned by Core Audio discovery.
///
/// This only describes the process. Live values such as level and waveform
/// belong to ApplicationAudioSourceModel below.
struct DiscoveredAudioProcess {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let applicationIcon: NSImage?
}

// MARK: - Observable row model

/// One persistent observable object per audio-producing application.
///
/// Each SwiftUI row observes one of these objects directly.
@MainActor
final class ApplicationAudioSourceModel: ObservableObject, Identifiable {
    nonisolated let id: AudioObjectID
    
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let applicationIcon: NSImage?

    @Published private(set) var level: Float = 0
    @Published private(set) var waveform: [Float]

    init(
        processObjectID: AudioObjectID,
        pid: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        applicationIcon: NSImage?
    ) {
        self.id = processObjectID
        self.processObjectID = processObjectID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.applicationIcon = applicationIcon
        self.waveform = Array(repeating: 0.06, count: 7)
    }

    /// Applies smoothing and publishes a new waveform frame.
    func push(rawLevel: Float) {
        let clampedRawLevel = min(max(rawLevel, 0), 1)

        let smoothedLevel: Float

        if clampedRawLevel > level {
            // Fast attack: react quickly when audio becomes louder.
            smoothedLevel =
                level + (clampedRawLevel - level) * 0.65
        } else {
            // Slower release: avoid an abrupt drop to zero.
            smoothedLevel =
                level + (clampedRawLevel - level) * 0.22
        }

        level = smoothedLevel

        var updatedWaveform = waveform

        if updatedWaveform.isEmpty {
            updatedWaveform = Array(repeating: 0.06, count: 7)
        } else {
            updatedWaveform.removeFirst()
        }

        updatedWaveform.append(max(0.06, smoothedLevel))

        // Assigning a new array makes this row object publish a change.
        waveform = updatedWaveform
    }
}

@MainActor
final class CombinedAudioSourceModel: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var waveform: [Float]

    init() {
        waveform = Array(repeating: 0.06, count: 7)
    }

    func push(rawLevel: Float) {
        let clampedLevel = min(max(rawLevel, 0), 1)

        let smoothedLevel: Float

        if clampedLevel > level {
            // Fast response when audio becomes louder.
            smoothedLevel =
                level + (clampedLevel - level) * 0.65
        } else {
            // Slower decay when audio becomes quieter.
            smoothedLevel =
                level + (clampedLevel - level) * 0.22
        }

        level = smoothedLevel

        var updated = waveform

        if updated.isEmpty {
            updated = Array(repeating: 0.06, count: 7)
        } else {
            updated.removeFirst()
        }

        updated.append(max(0.06, smoothedLevel))
        waveform = updated
    }

    func reset() {
        level = 0
        waveform = Array(repeating: 0.06, count: 7)
    }
}

// MARK: - Application monitor

@MainActor
final class ApplicationAudioMonitor: ObservableObject {
    static let shared = ApplicationAudioMonitor()

    @Published private(set)
    var activeSources: [ApplicationAudioSourceModel] = []

    @Published private(set)
    var lastError: String?

    let combinedSource = CombinedAudioSourceModel()

    private var sourceModels:
        [AudioObjectID: ApplicationAudioSourceModel] = [:]

    private var taps:
        [AudioObjectID: ProcessAudioTap] = [:]

    private var latestLevels:
        [AudioObjectID: Float] = [:]

    private var combinedTap: ProcessAudioTap?
    private var combinedProcessIDs: Set<AudioObjectID> = []
    private var latestCombinedLevel: Float = 0

    private var sourceTimer: Timer?
    private var waveformTimer: Timer?

    private init() {
        refreshSources()
        updateWaveforms()

        let sourceTimer = Timer(
            timeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSources()
            }
        }

        let waveformTimer = Timer(
            timeInterval: 0.06,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateWaveforms()
            }
        }

        self.sourceTimer = sourceTimer
        self.waveformTimer = waveformTimer

        // Common mode keeps both timers running during notch hover/tracking.
        RunLoop.main.add(sourceTimer, forMode: .common)
        RunLoop.main.add(waveformTimer, forMode: .common)
    }

    // MARK: - Source discovery

    private func refreshSources() {
        do {
            let discoveredProcesses = try Self.findActiveProcesses()
            reconcileSources(with: discoveredProcesses)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func findActiveProcesses() throws
        -> [DiscoveredAudioProcess]
    {
        let system = AudioHardwareSystem(
            id: AudioObjectID(kAudioObjectSystemObject)
        )

        let audioProcesses = try system.processes
        var discovered: [DiscoveredAudioProcess] = []

        for audioProcess in audioProcesses {
            guard try audioProcess.isRunningOutput else {
                continue
            }

            let pid = try audioProcess.pid

            // Do not display MyNook as its own source.
            guard pid != ProcessInfo.processInfo.processIdentifier else {
                continue
            }

            let bundleIdentifier = try audioProcess.bundleID

            let runningApplication =
                NSRunningApplication(processIdentifier: pid)

            let applicationName =
                runningApplication?.localizedName
                ?? bundleIdentifier
                ?? "Unknown Audio Process"

            discovered.append(
                DiscoveredAudioProcess(
                    processObjectID: audioProcess.id,
                    pid: pid,
                    bundleIdentifier: bundleIdentifier,
                    applicationName: applicationName,
                    applicationIcon: runningApplication?.icon
                )
            )
        }

        return discovered.sorted {
            $0.applicationName.localizedCaseInsensitiveCompare(
                $1.applicationName
            ) == .orderedAscending
        }
    }

    // MARK: - Source and tap reconciliation

    private func reconcileSources(
        with discoveredProcesses: [DiscoveredAudioProcess]
    ) {
        let discoveredIDs = Set(
            discoveredProcesses.map(\.processObjectID)
        )

        let existingIDs = Set(sourceModels.keys)
        let removedIDs = existingIDs.subtracting(discoveredIDs)

        // Remove applications that have stopped producing audio.
        for id in removedIDs {
            taps[id]?.stop()
            taps.removeValue(forKey: id)

            sourceModels.removeValue(forKey: id)
            latestLevels.removeValue(forKey: id)
        }

        // Add newly audible applications.
        for process in discoveredProcesses {
            let id = process.processObjectID

            if sourceModels[id] == nil {
                let model = ApplicationAudioSourceModel(
                    processObjectID: process.processObjectID,
                    pid: process.pid,
                    bundleIdentifier: process.bundleIdentifier,
                    applicationName: process.applicationName,
                    applicationIcon: process.applicationIcon
                )

                sourceModels[id] = model
                startTap(for: process, model: model)
            }
        }

        // Publish a stable array containing the persistent row objects.
        activeSources = discoveredProcesses.compactMap {
            sourceModels[$0.processObjectID]
        }
        reconcileCombinedTap(
            processIDs: discoveredProcesses.map(\.processObjectID)
        )
    }

    private func startTap(
        for process: DiscoveredAudioProcess,
        model: ApplicationAudioSourceModel
    ) {
        let sourceID = process.processObjectID

        let tap = ProcessAudioTap(
            processObjectIDs: [sourceID]
        ) { [weak self] level in
            Task { @MainActor in
                self?.latestLevels[sourceID] = level
            }
        }

        do {
            try tap.start()
            taps[sourceID] = tap
        } catch {
            lastError =
                "\(process.applicationName): " +
                error.localizedDescription

            latestLevels[sourceID] = 0
        }
    }

    // MARK: - Live waveform updates

    private func updateWaveforms() {
        for source in activeSources {
            let rawLevel =
                latestLevels[source.processObjectID] ?? 0

            source.push(rawLevel: rawLevel)
        }

        combinedSource.push(
            rawLevel: latestCombinedLevel
        )
    }
    
    private func reconcileCombinedTap(
        processIDs: [AudioObjectID]
    ) {
        let newProcessIDs = Set(processIDs)

        guard newProcessIDs != combinedProcessIDs else {
            return
        }

        combinedTap?.stop()
        combinedTap = nil

        combinedProcessIDs = newProcessIDs
        latestCombinedLevel = 0
        combinedSource.reset()

        guard !processIDs.isEmpty else {
            return
        }

        let tap = ProcessAudioTap(
            processObjectIDs: processIDs
        ) { [weak self] level in
            Task { @MainActor in
                self?.latestCombinedLevel = level
            }
        }

        do {
            try tap.start()
            combinedTap = tap
        } catch {
            lastError =
                "Combined audio tap: \(error.localizedDescription)"
        }
    }
}
