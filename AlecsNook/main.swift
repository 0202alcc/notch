//
//  main.swift
//  AlecsNook
//
//  Created by Alec Candidato on 7/19/26.
//

@preconcurrency import NookApp
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playing Audio")
                .font(.headline)

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AudioSourceRow: View {
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

            MiniAudioWaveform(
                levels: source.waveform
            )
        }
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

struct CombinedAudioWaveform: View {
    @ObservedObject var source: CombinedAudioSourceModel

    private var isActive: Bool {
        source.level > 0.065
    }

    var body: some View {
        MiniAudioWaveform(
            levels: source.waveform
        )
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
    hostTagline: "Custom notch controls",
    mark: { size, color in
        AnyView(
            ExpandedOutputStatusView(
                iconSize: size,
                activeColor: color
            )
        )
    }
)

// Expanded top-right
configuration.setTopBarTrailingItems {
    ExpandedMicrophoneStatusIcon()
}

NookApp.main(configuration)
