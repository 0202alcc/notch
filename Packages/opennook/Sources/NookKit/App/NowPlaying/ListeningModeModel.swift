//
//  ListeningModeModel.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// The AirPods noise-control modes, in "more cancellation" order.
///
/// These map 1:1 onto the labels Control Center renders in its Sound
/// panel's Listening Mode row. The platform only offers discrete modes
/// (Adaptive Audio is Apple's own dynamic blend - no continuous mix
/// parameter exists anywhere on the OS), so the slider experience is a
/// drag-onto-nearest-stop control over these four stops.
public enum ListeningMode: String, CaseIterable, Sendable {
    case off = "Off"
    case transparency = "Transparency"
    case adaptive = "Adaptive"
    case noiseCancellation = "Noise Cancellation"

    /// Parses a label exactly as it appears in the Control Center AX
    /// hierarchy. Unknown labels (e.g. "Not Available") parse to nil.
    public init?(axDescription: String) {
        self.init(rawValue: axDescription)
    }
}

/// Slider geometry for the listening modes currently offered by the
/// connected AirPods.
///
/// Positions are evenly spaced across the available modes; a drag
/// position resolves to the nearest stop. All arithmetic is pure -
/// tested without AirPods attached.
public struct ListeningModeModel: Equatable, Sendable {
    /// The available modes, in slider order (must be a subsequence of
    /// `ListeningMode.allCases`).
    public let available: [ListeningMode]

    public init(available: [ListeningMode]) {
        // Keep canonical ordering even if the caller hands modes in a
        // different order (the AX hierarchy is stable, but be defensive).
        let order = Dictionary(uniqueKeysWithValues: ListeningMode.allCases.enumerated().map { ($1, $0) })
        self.available = available.sorted { (order[$0] ?? 99) < (order[$1] ?? 99) }
    }

    /// Slider position (0...1) of a mode, or nil when the mode is not
    /// among the available stops.
    public func position(of mode: ListeningMode) -> Double? {
        guard
            let index = available.firstIndex(of: mode),
            !available.isEmpty
        else {
            return nil
        }
        guard available.count > 1 else { return 0 }
        return Double(index) / Double(available.count - 1)
    }

    /// The mode whose stop is nearest to a drag position. Positions
    /// outside 0...1 clamp.
    public func mode(at position: Double) -> ListeningMode? {
        guard !available.isEmpty else { return nil }
        guard available.count > 1 else { return available[0] }

        let clamped = min(max(position, 0), 1)
        let scaled = clamped * Double(available.count - 1)
        let index = Int((scaled).rounded())
        return available[min(max(index, 0), available.count - 1)]
    }
}
