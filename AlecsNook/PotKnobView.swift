//
//  PotKnobView.swift
//  AlecsNook
//
//  Created by Alec Candidato on 11/1/26.
//

import SwiftUI
import NookKit

/// Three rotary potentiometers (lows / mids / highs) for one routed
/// source. Drag up/down to change gain (-12...+12 dB); double-tap
/// resets the knob to flat.
struct SourceEQKnobs: View {
    let bundleID: String
    let ensureRouted: () -> Void

    @ObservedObject private var routes = RouteStore.shared

    var body: some View {
        HStack(spacing: 8) {
            PotKnob(label: "B", db: eqBinding(.low))
            PotKnob(label: "M", db: eqBinding(.mid))
            PotKnob(label: "T", db: eqBinding(.high))
        }
        .help("Per-source EQ: lows (B), mids (M), highs (T). Double-tap a knob to flatten it.")
    }

    private func eqBinding(_ band: EQBand) -> Binding<Double> {
        Binding(
            get: {
                guard let route = routes.routes[bundleID] else { return 0 }
                switch band {
                case .low: return route.eqLowDB
                case .mid: return route.eqMidDB
                case .high: return route.eqHighDB
                }
            },
            set: { newValue in
                ensureRouted()
                routes.setEqualizer(
                    forBundleIdentifier: bundleID,
                    band: band,
                    db: newValue
                )
            }
        )
    }
}

/// One rotary potentiometer. Vertical drag sweeps the gain; the
/// indicator line rotates -135°...+135° across the range.
struct PotKnob: View {
    let label: String
    @Binding var db: Double

    @State private var dragStartDB: Double?

    private static let sweepDegrees: Double = 270 // -135...+135

    private var angle: Double {
        let position = EQBand.knobPosition(forDB: db)
        return -Self.sweepDegrees / 2 + position * Self.sweepDegrees
    }

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 20, height: 20)

                // Tick marks at the flat position for orientation.
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: 20, height: 20)

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 9)
                    .offset(y: -5)
                    .rotationEffect(.degrees(angle))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartDB == nil {
                            dragStartDB = db
                        }
                        // 100pt of vertical travel = the full range.
                        let delta = -Double(value.translation.height) / 100.0
                            * (EQBand.maxDB - EQBand.minDB)
                        db = EQBand.clampDB((dragStartDB ?? 0) + delta)
                    }
                    .onEnded { _ in
                        dragStartDB = nil
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    db = 0
                }
            }

            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
