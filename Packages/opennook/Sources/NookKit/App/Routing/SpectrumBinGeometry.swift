//
//  SpectrumBinGeometry.swift
//  NookKit
//
//  Created by Alec Candidato on 11/1/26.
//

import Foundation

/// Maps log-spaced spectrum bins onto a log-frequency axis - the
/// geometry behind the live "dominant frequency" columns that light up
/// under the EQ response curve.
public enum SpectrumBinGeometry {
    /// Normalized (0...1) x-centers for `binCount` log-spaced bins
    /// spanning `minHz...maxHz`, on an axis whose own range is
    /// `axisMinHz...axisMaxHz` (the bins may cover a sub-range of the
    /// axis - e.g. FFT bins starting at 60 Hz on a 20 Hz axis).
    public static func normalizedCenters(
        binCount: Int,
        minHz: Double,
        maxHz: Double,
        axisMinHz: Double = 20,
        axisMaxHz: Double = 20000
    ) -> [Double] {
        guard binCount > 0, minHz > 0, maxHz > minHz else { return [] }

        let axisLogMin = log10(axisMinHz)
        let axisLogMax = log10(axisMaxHz)
        let axisSpan = axisLogMax - axisLogMin
        guard axisSpan > 0 else { return [] }

        let binLogMin = log10(minHz)
        let binLogMax = log10(maxHz)
        let binSpan = binLogMax - binLogMin

        return (0..<binCount).map { bin in
            // Center of this bin's log segment.
            let centerLog = binLogMin
                + ((Double(bin) + 0.5) / Double(binCount)) * binSpan
            return (centerLog - axisLogMin) / axisSpan
        }
    }
}
