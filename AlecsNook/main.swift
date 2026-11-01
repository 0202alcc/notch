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

/// Compact-row split-routing quick action (design decision: the picker
/// itself lives in the expanded panel; the compact button just signals
/// state and expands the nook on click).
struct CompactRouteQuickButton: View {
    @ObservedObject private var routes = RouteStore.shared
    @Environment(\.nookSurface) private var surface

    var body: some View {
        Button {
            Task { await surface?.expand(on: nil) }
        } label: {
            Image(
                systemName: routes.routingEnabled
                    ? "arrow.triangle.branch"
                    : "arrow.triangle.merge"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
                routes.routingEnabled ? Color.accentColor : .white.opacity(0.85)
            )
            .frame(width: 22, height: 24)
        }
        .buttonStyle(.plain)
        .help(
            routes.routingEnabled
                ? "Split routing on — click to manage per-app routes"
                : "Split routing off — sources play on the staging output"
        )
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

                Text("Staging output")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help(
                        "Where sources without their own route play. "
                        + "Changing this also changes the macOS system default."
                    )

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

            NoiseControlSlider()

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

/// AirPods noise-control slider: four discrete stops (the platform has
/// no continuous blend - Adaptive Audio is the system's own dynamic
/// mix). Dragging snaps to the nearest stop and presses the matching
/// Control Center checkbox through the AX hierarchy.
struct NoiseControlSlider: View {
    @ObservedObject private var controller = ListeningModeController.shared

    @State private var dragValue: Double?

    private var model: ListeningModeModel? {
        guard !controller.availableModes.isEmpty else { return nil }
        return ListeningModeModel(available: controller.availableModes)
    }

    private var shownValue: Double {
        dragValue
            ?? controller.currentMode
                .flatMap { model?.position(of: $0) }
            ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("AirPods noise control")

            if controller.accessibilityDenied {
                Button {
                    // Re-request (this is what adds AlecsNook to the
                    // Accessibility list) and deep-link straight to the
                    // exact pane.
                    let options = [
                        kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true,
                    ] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Enable noise control — opens System Settings → Accessibility")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .underline()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Grants the Accessibility permission AirPods noise control needs")
                Spacer()
            } else if let model {
                Slider(
                    value: Binding(
                        get: { shownValue },
                        set: { dragValue = $0 }
                    ),
                    in: 0...1
                ) { editing in
                    if !editing {
                        let position = dragValue ?? shownValue
                        if let mode = model.mode(at: position) {
                            controller.setMode(mode)
                        }
                        dragValue = nil
                    }
                }
                .frame(maxWidth: 170)

                Text(controller.currentMode?.rawValue ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .leading)
            } else {
                Text("Noise control available when AirPods are the output")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .onAppear {
            controller.refresh()
        }
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
                    Section("Staging outputs") {
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
            "Staging output - where unrouted sources play. Also the macOS system default."
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

    /// Device-appropriate icon for the replay volume control -
    /// headphones when the routed target is headphones (AirPods etc.).
    private static func volumeIconName(
        routes: [String: SourceRoute],
        outputDevices: OutputDeviceMonitor,
        bundleID: String
    ) -> String {
        guard let route = routes[bundleID] else {
            return "hifispeaker.fill"
        }
        let device = outputDevices.devices.first(where: {
            $0.uid == route.outputDeviceUID
                || (route.outputDeviceUID == nil
                    && $0.id == route.outputDeviceID)
        })
        return device?.symbolName ?? "hifispeaker.fill"
    }

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

            VStack(alignment: .leading, spacing: 2) {
                Text(source.applicationName)
                    .lineLimit(1)

                // Per-source replay volume - the effective volume while
                // the source is routed (the tap mutes its normal path,
                // so the replay player is the only audible copy).
                if
                    routes.routingEnabled,
                    let bundleID = source.bundleIdentifier,
                    routes.routes[bundleID]?.enabled == true
                {
                    HStack(spacing: 5) {
                        Image(
                            systemName: Self.volumeIconName(
                                routes: routes.routes,
                                outputDevices: outputDevices,
                                bundleID: bundleID
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: {
                                    routes.routes[bundleID]?.volume ?? 1
                                },
                                set: { newValue in
                                    routes.setVolume(
                                        forBundleIdentifier: bundleID,
                                        volume: newValue
                                    )
                                }
                            ),
                            in: 0...1
                        )
                        .frame(width: 100)
                        .help("Volume for \(source.applicationName) on its routed output")
                    }
                    .transition(.opacity)
                }
            }

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
        // Routed: the pinned device (UID-first match - the cached
        // AudioDeviceID can go stale when a device reconnects).
        if routes.routingEnabled, let route = currentRoute, route.enabled {
            let device = outputDevices.devices.first(where: { device in
                device.uid == route.outputDeviceUID
                    || (route.outputDeviceUID == nil
                        && device.id == route.outputDeviceID)
            })
            return device?.name ?? "Device offline"
        }

        // Unrouted: the label shows the *effective* destination - the
        // system default the top selector currently points at - so the
        // row never names a mode when it can name the actual device.
        return outputDevices.devices.first(where: {
            $0.id == outputDevices.currentOutputDeviceID
        })?.name ?? "System"
    }

    private var isRoutedToFixedDevice: Bool {
        routes.routingEnabled
            && currentRoute?.enabled == true
    }

    var body: some View {
        Menu {
            Button {
                disableRoute()
            } label: {
                Label(
                    "Follow staging output",
                    systemImage: currentRoute?.enabled != true
                        ? "checkmark"
                        : "circle"
                )
            }
            .help(
                "No split routing for this source - it plays on the staging output selected at the top"
            )

            Section("Output devices") {
                if outputDevices.devices.isEmpty {
                    Text("No output devices available")
                } else {
                    ForEach(outputDevices.devices) { device in
                        Button {
                            enableRoute(to: device)
                        } label: {
                            let active =
                                currentRoute?.enabled == true
                                && (currentRoute?.outputDeviceUID == device.uid
                                    || (currentRoute?.outputDeviceUID == nil
                                        && currentRoute?.outputDeviceID
                                            == device.id))
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
            }

            Section("Split routing") {
                Toggle(
                    "Enabled for all sources",
                    isOn: Binding(
                        get: { routes.routingEnabled },
                        set: { routes.setRoutingEnabled($0) }
                    )
                )
            }
        } label: {
            HStack(spacing: 3) {
                Image(
                    systemName: isRoutedToFixedDevice
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
            isRoutedToFixedDevice
                ? "Pinned to \(currentLabel) - click to change or release"
                : "Follows the staging output (\(currentLabel)) - click to pin a device"
        )
    }

    private func disableRoute() {
        guard let bundleID = source.bundleIdentifier else {
            return
        }
        routes.setEnabled(forBundleIdentifier: bundleID, enabled: false)

        // Last route gone: switch the master off too, so every tap
        // returns to plain observation and the replay engines tear
        // down. The reconcile sink handles the tap side.
        let anyEnabled = routes.routes.values.contains { $0.enabled }
        if !anyEnabled, routes.routingEnabled {
            routes.setRoutingEnabled(false)
        }
    }

    private func enableRoute(to device: OutputDevice) {
        guard let bundleID = source.bundleIdentifier else {
            return
        }
        // Picking a device for a source implies split routing is wanted -
        // the per-source picker previously showed the device label while
        // the master switch was off, so nothing actually routed.
        if !routes.routingEnabled {
            routes.setRoutingEnabled(true)
        }
        routes.setOutput(
            forBundleIdentifier: bundleID,
            deviceID: device.id,
            deviceUID: device.uid
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

// Pin the chrome to dark: the expanded panel should read as one continuous surface
// with the physical notch, which is black even in light mode. `.followSystem` paints
// solid white on a light-mode Mac, which looks broken against the real notch. This is
// a launch seed (see NookPreferenceDefaults) - a persisted user choice always wins.
configuration.preferenceDefaults.appearance.chromePalette = .dark

configuration.setHome {
    MyNookView()
}

// Collapsed state
configuration.setCompactLeading {
    CompactOutputStatusView()
}
configuration.setCompactTrailing {
    HStack(spacing: 2) {
        CompactRouteQuickButton()
        MicrophoneStatusIcon()
    }
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
