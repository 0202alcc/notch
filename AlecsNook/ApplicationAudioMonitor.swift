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
import os

/// Rate (Hz) at which we forward PCM samples from each tap into the
/// spectrum analyzer. Each tap delivers a buffer at the device's IO
/// schedule (~100 Hz), which is faster than the visualizer needs and
/// risks overloading the IO work loop when combined with the FFT work.
private let samplesForwardRate: Double = 30
private var samplesForwardInterval: TimeInterval { 1.0 / samplesForwardRate }

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
    @Published private(set) var spectrum: [Float]

    private let analyzer = AudioSpectrumAnalyzer(
        windowSize: 1024,
        binCount: 10
    )

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
        self.spectrum = Array(
            repeating: 0.06,
            count: 10
        )
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

    /// Runs an STFT over the supplied PCM samples and publishes the
    /// resulting magnitude bins as `spectrum`.
    func pushSamples(_ samples: [Float], sampleRate: Float) {
        let bins = analyzer.analyze(
            samples: samples,
            sampleRate: sampleRate
        )
        spectrum = bins
    }
}

@MainActor
final class CombinedAudioSourceModel: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var waveform: [Float]
    @Published private(set) var spectrum: [Float]

    private let analyzer = AudioSpectrumAnalyzer(
        windowSize: 1024,
        binCount: 10
    )

    init() {
        waveform = Array(repeating: 0.06, count: 7)
        spectrum = Array(repeating: 0.06, count: 10)
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

    func pushSamples(_ samples: [Float], sampleRate: Float) {
        let bins = analyzer.analyze(
            samples: samples,
            sampleRate: sampleRate
        )
        spectrum = bins
    }

    func reset() {
        level = 0
        waveform = Array(repeating: 0.06, count: 7)
        spectrum = Array(repeating: 0.06, count: 10)
    }
}

// MARK: - Application monitor

/// Selects how the audio waveform visualizations (notch + per-source rows)
/// render. Time-domain shows the rolling level bars; frequency-domain shows
/// an STFT magnitude spectrum.
enum WaveformStyle {
    case timeDomain
    case frequencyDomain
}

@MainActor
final class ApplicationAudioMonitor: ObservableObject {
    static let shared = ApplicationAudioMonitor()

    @Published private(set)
    var activeSources: [ApplicationAudioSourceModel] = []

    @Published private(set)
    var lastError: String?

    /// User-selected visualization mode for all waveform renderers in the
    /// app. Both the notch combined waveform and the per-source rows read
    /// this and switch together.
    @Published var waveformStyle: WaveformStyle = .timeDomain

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

    // Hysteresis state for source reconciliation.
    //
    // Core Audio's `kAudioProcessPropertyIsRunningOutput` is queried every
    // 0.5s and is known to flicker true for a single poll even when no real
    // audio is being produced (browsers cycling their audio engines, apps
    // briefly opening output streams, etc.). Acting on every poll caused
    // sources like Firefox to flash into the row and disappear within a
    // second. Count consecutive observations and only commit add/remove
    // transitions once a source has been stable across `sourceDebounce`
    // polls (~1s).
    private var pendingAddCounts: [AudioObjectID: Int] = [:]
    private var pendingRemoveCounts: [AudioObjectID: Int] = [:]
    private let sourceDebounce: Int = 2

    // After a source's tap is created we wait for the IO proc to actually
    // deliver a non-trivial level before exposing the row in `activeSources`.
    // `isRunningOutput` can remain true for a process that has already
    // stopped (or has never produced real audio — a muted tab, an idle
    // audio engine heartbeat, etc.) for several polls. Publishing the row
    // the instant the tap starts caused Firefox to flicker into the notch
    // and back out as its tap transitioned from cold 0-level to a stable
    // zero. Hiding the row until the level is real prevents the visual
    // flash and also catches a class of "no actual audio" false positives
    // that pure debounce can't.
    private var tapSettlePolls: [AudioObjectID: Int] = [:]
    private let sourceSettlePolls: Int = 2
    private let tapSettleLevelThreshold: Float = 0.005

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
        let candidateRemoveIDs = existingIDs.subtracting(discoveredIDs)

        // Reset remove streaks for sources that reappeared this poll so a
        // brief absence does not cascade into a removal.
        for id in discoveredIDs {
            pendingRemoveCounts.removeValue(forKey: id)
        }

        // Remove applications that have stopped producing audio, but only
        // after they have been absent for `sourceDebounce` consecutive polls.
        for id in candidateRemoveIDs {
            let next =
                (pendingRemoveCounts[id] ?? 0) + 1
            pendingRemoveCounts[id] = next

            if next >= sourceDebounce {
                taps[id]?.stop()
                taps.removeValue(forKey: id)

                sourceModels.removeValue(forKey: id)
                latestLevels.removeValue(forKey: id)
                pendingRemoveCounts.removeValue(forKey: id)
                tapSettlePolls.removeValue(forKey: id)
            }
        }

        // Add newly audible applications, but only after they have been
        // observed running output for `sourceDebounce` consecutive polls.
        for process in discoveredProcesses {
            let id = process.processObjectID

            if sourceModels[id] != nil {
                pendingAddCounts.removeValue(forKey: id)
                continue
            }

            let next =
                (pendingAddCounts[id] ?? 0) + 1
            pendingAddCounts[id] = next

            if next >= sourceDebounce {
                let model = ApplicationAudioSourceModel(
                    processObjectID: process.processObjectID,
                    pid: process.pid,
                    bundleIdentifier: process.bundleIdentifier,
                    applicationName: process.applicationName,
                    applicationIcon: process.applicationIcon
                )

                sourceModels[id] = model
                startTap(for: process, model: model)
                tapSettlePolls[id] = 0
                pendingAddCounts.removeValue(forKey: id)
            }
        }

        // Track which models have produced a real level during this poll
        // so we only publish rows that have settled.
        for id in sourceModels.keys {
            let level = latestLevels[id] ?? 0
            if level >= tapSettleLevelThreshold {
                if let count = tapSettlePolls[id] {
                    tapSettlePolls[id] = min(count + 1, sourceSettlePolls)
                }
            } else if tapSettlePolls[id] != nil {
                tapSettlePolls[id] = max((tapSettlePolls[id] ?? 0) - 1, 0)
            }
        }

        // Publish a stable array containing the persistent row objects,
        // but only for sources whose tap has produced real audio for at
        // least `sourceSettlePolls` consecutive polls. This prevents a
        // tap that only ever reports 0 (a misbehaving or genuinely silent
        // source) from flashing into the UI.
        activeSources = discoveredProcesses.compactMap {
            process -> ApplicationAudioSourceModel? in
            let id = process.processObjectID

            guard let model = sourceModels[id] else {
                return nil
            }

            if (tapSettlePolls[id] ?? 0) >= sourceSettlePolls {
                return model
            }

            return nil
        }
        reconcileCombinedTap(
            settledProcessIDs: settledProcessIDs(
                from: discoveredProcesses
            )
        )
    }

    /// Returns the subset of `discoveredProcesses` whose tap has produced
    /// real audio for at least `sourceSettlePolls` consecutive polls. The
    /// combined tap is built from this filtered set so transient false
    /// positives (e.g. Firefox's idle audio-engine heartbeat) never
    /// enter the combined source set and never cause it to be torn down
    /// and rebuilt.
    private func settledProcessIDs(
        from discoveredProcesses: [DiscoveredAudioProcess]
    ) -> [AudioObjectID] {
        discoveredProcesses.compactMap { process in
            let id = process.processObjectID

            guard sourceModels[id] != nil else {
                return nil
            }

            if (tapSettlePolls[id] ?? 0) >= sourceSettlePolls {
                return id
            }

            return nil
        }
    }

    private func startTap(
        for process: DiscoveredAudioProcess,
        model: ApplicationAudioSourceModel
    ) {
        let sourceID = process.processObjectID
        let bundleID = process.bundleIdentifier

        // Per-tap throttle for the spectrum path. `OSAllocatedUnfairLock`
        // is `Sendable`, so it's safe to capture in the `@Sendable`
        // samples handler closure. The IO callback queue is serial, so
        // contention is essentially zero in practice; the lock exists
        // primarily to satisfy Swift's concurrency rules.
        let samplesThrottle =
            OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

        let tap = ProcessAudioTap(
            processObjectIDs: [sourceID],
            levelHandler: { [weak self] level in
                Task { @MainActor in
                    self?.latestLevels[sourceID] = level
                }
            },
            samplesHandler: { [weak self] bufferList in
                let now = CFAbsoluteTimeGetCurrent()
                let shouldForward = samplesThrottle.withLock { last in
                    if now - last >= samplesForwardInterval {
                        last = now
                        return true
                    }
                    return false
                }
                guard shouldForward else { return }

                let samples = Self.copySamples(from: bufferList)

                // Forward to the spectrum analyzer for visualization
                // (existing path).
                Task { @MainActor in
                    guard let self else { return }
                    guard
                        let model = self.sourceModels[sourceID]
                    else {
                        return
                    }
                    model.pushSamples(samples, sampleRate: 48_000)
                }

                // Forward to AudioRouter for per-source output routing.
                // The router consults RouteStore lock-free and only
                // does work if this source has an enabled route, so
                // the no-route case is essentially free.
                AudioRouter.shared.handleSamples(
                    fromSourceObjectID: sourceID,
                    bundleIdentifier: bundleID,
                    bufferList: bufferList,
                    frameCount: samples.count,
                    sampleRate: 48_000
                )
            }
        )

        do {
            try tap.start()
            taps[sourceID] = tap
        } catch {
            lastError =
                "\(process.applicationName): " +
                error.localizedDescription

            latestLevels[sourceID] = 0
        }

        // Register / refresh the route entry for this source so the
        // UI can show a picker for it even before the user has made a
        // routing choice.
        RouteStore.shared.upsertRoute(
            SourceRoute(
                sourceObjectID: sourceID,
                bundleIdentifier: bundleID,
                applicationName: process.applicationName
            )
        )
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
        settledProcessIDs processIDs: [AudioObjectID]
    ) {
        let newProcessIDs = Set(processIDs)

        guard newProcessIDs != combinedProcessIDs else {
            return
        }

        // Only zero out the combined waveform when the source set has
        // truly become empty. When the membership changes but the set is
        // still non-empty (e.g. a new source settles in, an old one
        // leaves) we still rebuild the tap so the level reflects the new
        // membership, but we let the existing waveform decay naturally
        // through the smoothing pass rather than snapping it to baseline
        // — that snap was visible as a frame-long flicker in the notch.
        let isBecomingEmpty = processIDs.isEmpty

        combinedTap?.stop()
        combinedTap = nil

        combinedProcessIDs = newProcessIDs

        if isBecomingEmpty {
            latestCombinedLevel = 0
            combinedSource.reset()
        }

        guard !processIDs.isEmpty else {
            return
        }

        let samplesThrottle =
            OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

        let tap = ProcessAudioTap(
            processObjectIDs: processIDs,
            levelHandler: { [weak self] level in
                Task { @MainActor in
                    self?.latestCombinedLevel = level
                }
            },
            samplesHandler: { [weak self] bufferList in
                let now = CFAbsoluteTimeGetCurrent()
                let shouldForward = samplesThrottle.withLock { last in
                    if now - last >= samplesForwardInterval {
                        last = now
                        return true
                    }
                    return false
                }
                guard shouldForward else { return }

                let samples = Self.copySamples(from: bufferList)
                Task { @MainActor in
                    guard let self else { return }
                    self.combinedSource.pushSamples(
                        samples,
                        sampleRate: 48_000
                    )
                }
            }
        )

        do {
            try tap.start()
            combinedTap = tap
        } catch {
            lastError =
                "Combined audio tap: \(error.localizedDescription)"
        }
    }

    // MARK: - Sample copy

    /// Copies every channel of an `AudioBufferList` into a single `Float`
    /// array (channels laid out back-to-back). The receiver is responsible
    /// for down-mixing to mono. Marked `nonisolated` because it runs on
    /// the tap's IO callback queue, not the main actor.
    private nonisolated static func copySamples(
        from bufferListPointer: UnsafePointer<AudioBufferList>
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferListPointer)
        )

        var result: [Float] = []
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

            guard count > 0 else { continue }

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
}
