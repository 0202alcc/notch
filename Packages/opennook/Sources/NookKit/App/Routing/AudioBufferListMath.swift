//
//  AudioBufferListMath.swift
//  NookKit
//
//  Created by Alec Candidato on 10/31/26.
//

import CoreAudio
import Foundation

/// Pure, allocation-free helpers for reading Core Audio `AudioBufferList`s.
///
/// Process taps deliver either an interleaved layout (one buffer carrying
/// all channels) or a non-interleaved/planar layout (one buffer per
/// channel). Both appear in practice depending on the tap and device
/// configuration, so everything that consumes tap output - the RMS meter,
/// the spectrum forwarder, and the split-routing replay path - must
/// interpret the list by its actual shape, never by assumption.
///
/// All functions are safe to call from the real-time audio thread: no
/// locks, no allocation beyond the arrays the caller explicitly requests.
public enum AudioBufferListMath {
    /// Frame count of an `AudioBufferList`, valid for both interleaved
    /// and non-interleaved layouts. Takes the maximum across buffers so
    /// a planar list (one buffer per channel, identical frame counts)
    /// is not double-counted.
    public static func frameCount(
        of bufferList: UnsafePointer<AudioBufferList>
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )

        var frames = 0
        for buffer in buffers where buffer.mDataByteSize > 0 {
            let channels = max(Int(buffer.mNumberChannels), 1)
            let bufferFrames =
                Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * channels)
            frames = max(frames, bufferFrames)
        }
        return frames
    }

    /// Channel count declared by the buffer list.
    ///
    /// Interleaved: `mNumberBuffers == 1` with `mNumberChannels > 1`.
    /// Planar: one buffer per channel, each declaring 1.
    public static func channelCount(
        of bufferList: UnsafePointer<AudioBufferList>
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )

        var channels = 0
        for buffer in buffers where buffer.mDataByteSize > 0 {
            channels = max(channels, Int(buffer.mNumberChannels))
        }
        return max(channels, buffers.count)
    }

    /// Splits an `AudioBufferList` into one sample array per channel,
    /// normalizing both layouts to planar. Channel `i` of the result is
    /// `frameCount` samples long (short arrays are padded with zeros so
    /// callers can index every frame safely).
    public static func planarChannels(
        of bufferList: UnsafePointer<AudioBufferList>
    ) -> (channels: [[Float]], frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )

        let frameCount = frameCount(of: bufferList)
        let channelTotal = channelCount(of: bufferList)
        guard frameCount > 0, channelTotal > 0 else {
            return ([], 0)
        }

        var planar = [[Float]](repeating: [Float](), count: channelTotal)
        for index in planar.indices {
            planar[index].reserveCapacity(frameCount)
        }

        var filled = 0
        for buffer in buffers {
            guard
                buffer.mDataByteSize > 0,
                let data = buffer.mData
            else {
                continue
            }

            let channels = max(Int(buffer.mNumberChannels), 1)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)

            if channels > 1 {
                // Interleaved buffer: stride by channel count.
                for frame in 0..<count / channels {
                    for channel in 0..<channels {
                        planar[channel].append(samples[frame * channels + channel])
                    }
                }
                filled = max(filled, channels)
            } else {
                // Planar buffer: one channel's worth of frames.
                let target = filled
                if target < channelTotal {
                    planar[target].append(
                        contentsOf: UnsafeBufferPointer(
                            start: samples,
                            count: count
                        )
                    )
                    filled += 1
                }
            }
        }

        // Pad short channels so every channel is frameCount long.
        for index in planar.indices {
            if planar[index].count < frameCount {
                planar[index].append(
                    contentsOf: [Float](
                        repeating: 0,
                        count: frameCount - planar[index].count
                    )
                )
            }
        }

        return (planar, frameCount)
    }
}
