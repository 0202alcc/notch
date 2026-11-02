//
//  PotKnobView.swift
//  AlecsNook
//
//  Created by Alec Candidato on 11/1/26.
//

import SwiftUI
import NookKit

/// The live combined EQ response, rendered above the potentiometers -
/// recomputes from the route's gains on every knob move (the same RBJ
/// math the engine runs; 96 log-spaced samples, ±14 dB window).
struct EQResponseCurveView: View {
    let bundleID: String

    @ObservedObject private var routes = RouteStore.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let route = routes.routes[bundleID]
            let curve = EQResponseCurveMath.combinedResponseDB(
                low: route?.eqLowDB ?? 0,
                mid: route?.eqMidDB ?? 0,
                high: route?.eqHighDB ?? 0
            )

            Canvas { context, _ in
                let zeroY = h / 2
                let dBRange = 28.0 // ±14 dB visible
                let stepX = w / Double(EQResponseCurveMath.sampleCount - 1)

                func yFor(_ db: Double) -> CGFloat {
                    CGFloat(zeroY - (db / dBRange) * (h / 2))
                }

                // 0 dB reference line.
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: zeroY))
                zero.addLine(to: CGPoint(x: w, y: zeroY))
                context.stroke(
                    zero,
                    with: .color(Color.secondary.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
                )

                // Western-scale axis: A-octave markers (A0..A9).
                let logMin = log10(EQResponseCurveMath.minFrequencyHz)
                let logMax = log10(EQResponseCurveMath.maxFrequencyHz)
                func xFor(_ f: Double) -> CGFloat {
                    let t = (log10(f) - logMin) / (logMax - logMin)
                    return CGFloat(t) * w
                }
                for marker in EQResponseCurveMath.octaveMarkers() {
                    let x = xFor(marker.frequencyHz)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: zeroY - 3))
                    tick.addLine(to: CGPoint(x: x, y: zeroY + 3))
                    context.stroke(
                        tick,
                        with: .color(Color.secondary.opacity(0.4)),
                        lineWidth: 0.75
                    )
                    context.draw(
                        Text(marker.name)
                            .font(.system(size: 6, weight: .medium))
                            .foregroundStyle(Color.secondary.opacity(0.75)),
                        at: CGPoint(x: x, y: h - 6)
                    )
                }

                // The three band corners, with their nearest notes.
                for (band, note) in [
                    (EQBand.low, EQResponseCurveMath.noteName(forHz: 150)),
                    (EQBand.mid, EQResponseCurveMath.noteName(forHz: 1000)),
                    (EQBand.high, EQResponseCurveMath.noteName(forHz: 6000)),
                ] {
                    let x = xFor(band.frequencyHzValue)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 2))
                    tick.addLine(to: CGPoint(x: x, y: zeroY - 4))
                    context.stroke(
                        tick,
                        with: .color(Color.accentColor.opacity(0.5)),
                        lineWidth: 0.75
                    )
                    context.draw(
                        Text(note)
                            .font(.system(size: 6, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.85)),
                        at: CGPoint(x: x, y: 7)
                    )
                }

                // Filled area between the curve and the 0 dB line.
                var area = Path()
                var line = Path()
                for (index, db) in curve.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * stepX, y: yFor(db))
                    if index == 0 {
                        area.move(to: point)
                        line.move(to: point)
                    } else {
                        area.addLine(to: point)
                        line.addLine(to: point)
                    }
                }
                area.addLine(to: CGPoint(x: w, y: zeroY))
                area.addLine(to: CGPoint(x: 0, y: zeroY))
                area.closeSubpath()

                context.fill(
                    area,
                    with: .color(Color.accentColor.opacity(0.28))
                )
                context.stroke(
                    line,
                    with: .color(Color.accentColor),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Live EQ response of this source: how the knobs reshape the spectrum - axis marked in Western note names (A octaves)")
    }
}

/// Three rotary potentiometers (lows / mids / highs) for one routed
/// source. Drag up/down to change gain (-12...+12 dB); double-tap
/// resets the knob to flat.
struct SourceEQKnobs: View {
    let bundleID: String
    let ensureRouted: () -> Void

    @ObservedObject private var routes = RouteStore.shared

    var body: some View {
        HStack(spacing: 8) {
            PotKnob(label: EQBand.low.label, db: eqBinding(.low))
            PotKnob(label: EQBand.mid.label, db: eqBinding(.mid))
            PotKnob(label: EQBand.high.label, db: eqBinding(.high))
        }
        .help("Per-source EQ: 150Hz lows, 1kHz mids, 6kHz highs. Double-tap a knob to flatten it.")
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
                        // Horizontal drag = spinning the pot. The
                        // indicator rotation tracks the drag 1:1
                        // (degrees per point), clamped at the physical
                        // end-stops (-135...+135).
                        if dragStartDB == nil {
                            dragStartDB = db
                        }
                        let sweep = Self.sweepDegrees
                        let startAngle =
                            -sweep / 2
                            + EQBand.knobPosition(forDB: dragStartDB ?? 0)
                                * sweep
                        let newAngle = min(
                            max(startAngle + Double(value.translation.width), -sweep / 2),
                            sweep / 2
                        )
                        let position = (newAngle + sweep / 2) / sweep
                        db = EQBand.db(forKnobPosition: position)
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
                .font(.system(size: 6.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
