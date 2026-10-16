//
//  main.swift
//  AlecsNook
//
//  Created by Alec Candidato on 7/19/26.
//

@preconcurrency import NookApp
import CoreAudio
import SwiftUI

struct MyNookView: View {
    var body: some View {
        ActiveAudioSourcesView()
            .padding()
    }
}

struct SpeakerStatusIcon: View {
    @ObservedObject private var audio = AudioMuteMonitor.shared

    var size: CGFloat = 12
    var activeColor: Color = .white

    var body: some View {
        Image(
            systemName: audio.isSpeakerMuted
                ? "speaker.slash.fill"
                : "speaker.wave.2.fill"
        )
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(
            audio.isSpeakerMuted ? .red : activeColor
        )
        .contentTransition(.symbolEffect(.replace))
        .help(
            audio.isSpeakerMuted
                ? "Speakers muted"
                : "Speakers active"
        )
    }
}

struct MicrophoneStatusIcon: View {
    @ObservedObject private var audio = AudioMuteMonitor.shared

    var body: some View {
        Image(
            systemName: audio.isMicrophoneInUse
                ? "mic.fill"
                : "mic"
        )
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(
            audio.isMicrophoneInUse ? .orange : .white
        )
        .frame(width: 26, height: 24)
        .help(
            audio.isMicrophoneInUse
                ? "Microphone in use"
                : "Microphone idle"
        )
    }
}

struct ExpandedMicrophoneStatusIcon: View {
    var body: some View {
        MicrophoneStatusIcon()
    }
}

struct ActiveAudioSourcesView: View {
    @ObservedObject private var monitor =
        ApplicationAudioMonitor.shared

    @ObservedObject private var outputDevices =
        OutputDeviceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Playing Audio")
                    .font(.headline)

                Spacer()

                OutputDeviceMenu()

                Picker(
                    "Waveform style",
                    selection: $monitor.waveformStyle
                ) {
                    Image(systemName: "waveform")
                        .tag(WaveformStyle.timeDomain)
                        .help("Time-domain bars")
                    Image(systemName: "chart.bar.fill")
                        .tag(WaveformStyle.frequencyDomain)
                        .help("Frequency-domain (STFT)")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if monitor.activeSources.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .foregroundStyle(.secondary)

                    Text("No applications are producing audio")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(monitor.activeSources) { source in
                    AudioSourceRow(source: source)
                }
            }

            if let error = monitor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let error = outputDevices.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        outputDevices.clearError()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact menu that shows the current output device and lets the user
/// switch to a different one. All discovery, dedup, and active device
/// tracking lives in `OutputDeviceMonitor`; this view just renders it.
struct OutputDeviceMenu: View {
    @ObservedObject private var outputDevices =
        OutputDeviceMonitor.shared

    private var currentDeviceName: String {
        guard
            let id = outputDevices.currentOutputDeviceID,
            let device = outputDevices.devices.first(where: {
                $0.id == id
            })
        else {
            return "Select output"
        }
        return device.name
    }

    var body: some View {
        Menu {
            if outputDevices.devices.isEmpty
                && outputDevices.airplayDevices.isEmpty
            {
                Text("No output devices available")
            } else {
                if !outputDevices.devices.isEmpty {
                    Section("Devices") {
                        ForEach(outputDevices.devices) { device in
                            outputDeviceButton(device)
                        }
                    }
                }

                if !outputDevices.airplayDevices.isEmpty {
                    Section("AirPlay") {
                        ForEach(outputDevices.airplayDevices) { device in
                            airplayDeviceButton(device)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                Text(currentDeviceName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            outputDevices.devices.first(where: {
                $0.id == outputDevices.currentOutputDeviceID
            })?.isAvailable == false
                ? "Currently disconnected"
                : "Switch output device"
        )
    }

    @ViewBuilder
    private func outputDeviceButton(_ device: OutputDevice) -> some View {
        Button {
            if device.isAvailable {
                outputDevices.setDefaultOutputDevice(device.id)
            }
        } label: {
            if device.id == outputDevices.currentOutputDeviceID {
                Label(device.name, systemImage: "checkmark")
            } else if device.isAvailable {
                Text(device.name)
            } else {
                Label(device.name, systemImage: "wifi.exclamationmark")
            }
        }
        .disabled(!device.isAvailable)
    }

    /// Bonjour-discovered AirPlay receivers. These don't have a
    /// Core Audio device ID yet (the TV has never been paired with
    /// this Mac), so the menu entry is informational — selecting it
    /// does nothing, with a help hint explaining how to actually pair
    /// the receiver.
    @ViewBuilder
    private func airplayDeviceButton(
        _ device: AirPlayDevice
    ) -> some View {
        Label(
            device.bonjourName,
            systemImage: device.isResolving
                ? "airplayaudio"
                : "airplayaudio"
        )
        .help(
            device.isResolving
                ? "Resolving \(device.bonjourName) on the network…"
                : "\(device.bonjourName) is on the network. "
                + "Pick it in System Settings → Sound to pair it once; "
                + "it will then appear as a routable device here."
        )
    }
}

struct AudioSourceRow: View {
    @ObservedObject private var monitor =
        ApplicationAudioMonitor.shared

    @ObservedObject private var outputDevices =
        OutputDeviceMonitor.shared

    @ObservedObject private var routes =
        RouteStore.shared

    @ObservedObject var source: ApplicationAudioSourceModel

    var body: some View {
        HStack(spacing: 10) {
            if let icon = source.applicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app")
                    .frame(width: 24, height: 24)
            }

            Text(source.applicationName)
                .lineLimit(1)

            Spacer()

            SourceRouteMenu(source: source)

            switch monitor.waveformStyle {
            case .timeDomain:
                MiniAudioWaveform(
                    levels: source.waveform
                )
            case .frequencyDomain:
                MiniAudioSpectrum(
                    spectrum: source.spectrum
                )
            }
        }
    }
}

/// Compact per-source output-device picker.
///
/// Shows the name of the currently-routed device (or "System default"
/// when the source has no explicit route). The menu lists every
/// currently-available output device plus "System default" at the
/// top, plus an "Off / follow system default" entry that disables
/// replay for this source.
struct SourceRouteMenu: View {
    @ObservedObject private var outputDevices =
        OutputDeviceMonitor.shared

    @ObservedObject private var routes =
        RouteStore.shared

    let source: ApplicationAudioSourceModel

    private var currentRoute: SourceRoute? {
        guard let bundleID = source.bundleIdentifier else {
            return nil
        }
        return routes.routes[bundleID]
    }

    private var currentLabel: String {
        guard
            let route = currentRoute,
            route.enabled,
            let deviceID = route.outputDeviceID,
            let device = outputDevices.devices.first(where: {
                $0.id == deviceID
            })
        else {
            return "System"
        }
        return device.name
    }

    var body: some View {
        Menu {
            Button {
                disableRoute()
            } label: {
                Label(
                    "System default",
                    systemImage: currentRoute?.enabled != true
                        ? "checkmark"
                        : "circle"
                )
            }

            Divider()

            if outputDevices.devices.isEmpty {
                Text("No output devices available")
            } else {
                ForEach(outputDevices.devices) { device in
                    Button {
                        enableRoute(to: device.id)
                    } label: {
                        let active =
                            currentRoute?.enabled == true
                            && currentRoute?.outputDeviceID
                                == device.id
                        if active {
                            Label(
                                device.name,
                                systemImage: "checkmark"
                            )
                        } else if device.isAvailable {
                            Text(device.name)
                        } else {
                            Label(
                                device.name,
                                systemImage: "wifi.exclamationmark"
                            )
                        }
                    }
                    .disabled(!device.isAvailable)
                }
            }

            Divider()

            Toggle(
                "Per-source routing",
                isOn: Binding(
                    get: { routes.routingEnabled },
                    set: { routes.setRoutingEnabled($0) }
                )
            )
        } label: {
            HStack(spacing: 3) {
                Image(
                    systemName: routes.routingEnabled
                        ? "arrow.triangle.branch"
                        : "speaker.wave.2"
                )
                .font(.caption2)
                Text(currentLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            routes.routingEnabled
                ? "Route \(source.applicationName) to a specific output"
                : "Enable per-source routing to pick a non-default output"
        )
    }

    private func disableRoute() {
        guard let bundleID = source.bundleIdentifier else {
            return
        }
        routes.setEnabled(forBundleIdentifier: bundleID, enabled: false)
    }

    private func enableRoute(to deviceID: AudioDeviceID) {
        guard let bundleID = source.bundleIdentifier else {
            return
        }
        routes.setOutput(
            forBundleIdentifier: bundleID,
            deviceID: deviceID
        )
        routes.setEnabled(forBundleIdentifier: bundleID, enabled: true)
    }
}

struct MiniAudioWaveform: View {
    let levels: [Float]

    private let heightPattern: [CGFloat] = [
        0.55, 0.8, 1.0, 0.7, 0.9, 0.65, 0.5
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) {
                index,
                rawLevel in

                let level = CGFloat(rawLevel)
                let pattern =
                    heightPattern[index % heightPattern.count]

                Capsule()
                    .frame(
                        width: 2,
                        height: max(
                            2,
                            16 * level * pattern
                        )
                    )
            }
        }
        .frame(width: 26, height: 18)
        .animation(
            .linear(duration: 0.06),
            value: levels
        )
    }
}

/// Compact magnitude spectrum (STFT output) rendered as a row of bars.
///
/// Each entry in `spectrum` is a smoothed, log-spaced magnitude bin in
/// roughly `0...1`. The number of bars is determined by the array length.
struct MiniAudioSpectrum: View {
    let spectrum: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 0.5) {
            ForEach(Array(spectrum.enumerated()), id: \.offset) {
                _, rawMagnitude in
                let magnitude = CGFloat(
                    min(max(rawMagnitude, 0), 1)
                )

                Capsule()
                    .frame(
                        width: 2,
                        height: max(2, 16 * magnitude)
                    )
            }
        }
        .frame(width: 26, height: 18)
        .animation(
            .linear(duration: 0.06),
            value: spectrum
        )
    }
}

struct CombinedAudioWaveform: View {
    @ObservedObject private var monitor =
        ApplicationAudioMonitor.shared

    @ObservedObject var source: CombinedAudioSourceModel

    private var isActive: Bool {
        source.level > 0.065
    }

    var body: some View {
        Group {
            switch monitor.waveformStyle {
            case .timeDomain:
                MiniAudioWaveform(levels: source.waveform)
            case .frequencyDomain:
                MiniAudioSpectrum(spectrum: source.spectrum)
            }
        }
        .opacity(isActive ? 1 : 0)
        .frame(
            width: isActive ? 26 : 0,
            height: 18
        )
        .clipped()
        .animation(
            .easeInOut(duration: 0.16),
            value: isActive
        )
        .help("Combined audio output")
    }
}

struct CompactOutputStatusView: View {
    @ObservedObject private var muteMonitor =
        AudioMuteMonitor.shared

    @ObservedObject private var combinedSource =
        ApplicationAudioMonitor.shared.combinedSource

    var body: some View {
        HStack(spacing: 5) {
            SpeakerStatusIcon()

            if !muteMonitor.isSpeakerMuted {
                CombinedAudioWaveform(
                    source: combinedSource
                )
            }
        }
        .fixedSize()
        .padding(.trailing, 4)
        .frame(height: 24)
    }
}

struct ExpandedOutputStatusView: View {
    @ObservedObject private var combinedSource =
        ApplicationAudioMonitor.shared.combinedSource

    var iconSize: CGFloat
    var activeColor: Color

    var body: some View {
        HStack(spacing: 5) {
            SpeakerStatusIcon(
                size: iconSize,
                activeColor: activeColor
            )

            CombinedAudioWaveform(
                source: combinedSource
            )
        }
        .fixedSize()
    }
}

var configuration = NookConfiguration()

configuration.setHome {
    MyNookView()
}

// Collapsed state
configuration.setCompactLeading {
    CompactOutputStatusView()
}
configuration.setCompactTrailing {
    MicrophoneStatusIcon()
}

// Expanded top-left
configuration.topBar.leadingIcon = nil
configuration.topBar.leadingTitle = { _ in "" }

configuration.branding = NookHostBranding(
    hostName: "MyNook",
    hostTagline: "Custom notch controls"
)

// Expanded top-right
configuration.setTopBarTrailingItems {
    ExpandedMicrophoneStatusIcon()
}

NookApp.main(configuration)
