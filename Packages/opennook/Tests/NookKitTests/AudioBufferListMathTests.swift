//
//  AudioBufferListMathTests.swift
//  NookKitTests
//
//  Created by Alec Candidato on 10/31/26.
//

import CoreAudio
import XCTest

@testable import NookKit

/// Owns the raw memory for a test-constructed `AudioBufferList`. Data
/// blocks are allocated separately and pointed at via `mData`, which the
/// buffer-list math never assumes to be contiguous with the header.
private final class TestBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private var dataBlocks: [UnsafeMutableRawPointer] = []

    init(buffers: [(channels: UInt32, byteSize: UInt32)]) {
        // Room for the header plus a flexible mBuffers array of
        // `buffers.count` entries (the struct type only declares one).
        let byteCount =
            MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * (buffers.count - 1)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = UInt32(buffers.count)

        let mutable = UnsafeMutableAudioBufferListPointer(pointer)
        for (index, spec) in buffers.enumerated() {
            let block = UnsafeMutableRawPointer.allocate(
                byteCount: Int(spec.byteSize),
                alignment: MemoryLayout<Float>.alignment
            )
            block.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: Int(spec.byteSize)
            )
            dataBlocks.append(block)
            mutable[index].mNumberChannels = spec.channels
            mutable[index].mDataByteSize = spec.byteSize
            mutable[index].mData = block
        }
    }

    deinit {
        for block in dataBlocks {
            block.deallocate()
        }
        pointer.deallocate()
    }    /// Raw float storage of buffer `index`.
    func floats(_ index: Int) -> UnsafeMutablePointer<Float> {
        dataBlocks[index].assumingMemoryBound(to: Float.self)
    }

    var unsafeList: UnsafePointer<AudioBufferList> {
        UnsafePointer(pointer)
    }
}

/// Locks the buffer-shape interpretation the split-routing replay path
/// depends on: taps can deliver interleaved or planar `AudioBufferList`s
/// and both must read identically through ``AudioBufferListMath``.
final class AudioBufferListMathTests: XCTestCase {
    private let frames = 512

    private func makeInterleavedStereo() -> TestBufferList {
        let byteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        let box = TestBufferList(buffers: [(channels: 2, byteSize: byteSize)])
        let samples = box.floats(0)
        for frame in 0..<frames {
            samples[frame * 2] = Float(frame)       // left
            samples[frame * 2 + 1] = Float(-frame)  // right
        }
        return box
    }

    private func makePlanarStereo() -> TestBufferList {
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        let box = TestBufferList(buffers: [
            (channels: 1, byteSize: byteSize),
            (channels: 1, byteSize: byteSize),
        ])
        for frame in 0..<frames {
            box.floats(0)[frame] = Float(frame)
            box.floats(1)[frame] = Float(-frame)
        }
        return box
    }

    func testFrameCountInterleavedStereo() {
        let box = makeInterleavedStereo()
        defer { /* deallocated with box */ }

        XCTAssertEqual(
            AudioBufferListMath.frameCount(of: box.unsafeList),
            frames,
            "interleaved byte size must divide by channels, not be read as raw floats"
        )
    }

    func testFrameCountPlanarStereo() {
        let box = makePlanarStereo()

        XCTAssertEqual(
            AudioBufferListMath.frameCount(of: box.unsafeList),
            frames,
            "planar buffers must not be summed into a double frame count"
        )
    }

    func testChannelCountBothLayouts() {
        let interleaved = makeInterleavedStereo()
        let planar = makePlanarStereo()

        let interleavedChannels = AudioBufferListMath.channelCount(
            of: interleaved.unsafeList
        )
        let planarChannels = AudioBufferListMath.channelCount(
            of: planar.unsafeList
        )

        XCTAssertEqual(interleavedChannels, 2)
        XCTAssertEqual(planarChannels, 2)
    }

    func testPlanarChannelsFromInterleaved() {
        let box = makeInterleavedStereo()

        let (channels, frameCount) = AudioBufferListMath.planarChannels(
            of: box.unsafeList
        )

        XCTAssertEqual(frameCount, frames)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0][0], 0)
        XCTAssertEqual(channels[1][0], 0) // -0.0 == 0
        XCTAssertEqual(channels[0][1], 1)
        XCTAssertEqual(channels[1][1], -1)
        XCTAssertEqual(channels[0][frames - 1], Float(frames - 1))
    }

    func testPlanarChannelsFromPlanar() {
        let box = makePlanarStereo()

        let (channels, frameCount) = AudioBufferListMath.planarChannels(
            of: box.unsafeList
        )

        XCTAssertEqual(frameCount, frames)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0][7], 7)
        XCTAssertEqual(channels[1][7], -7)
    }

    func testEmptyBufferListYieldsNothing() {
        let box = TestBufferList(buffers: [(channels: 2, byteSize: 0)])

        let (channels, frameCount) = AudioBufferListMath.planarChannels(
            of: box.unsafeList
        )

        XCTAssertEqual(frameCount, 0)
        XCTAssertTrue(channels.isEmpty)
    }
}
