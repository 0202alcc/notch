// M1.5 probe: capture 10s of live system audio via a CoreAudio process
// tap, then run it through HTDemucs and check the stems.
import CoreML
import Foundation
import AVFoundation
import CoreAudio
import Accelerate

setvbuf(stdout, nil, _IONBF, 0)

let fs = 48000.0
let captureSeconds = 10.0
let captureSamples = Int(captureSeconds * fs)

// ---- Capture: tap ALL running-output processes (like ProcessAudioTap) ----

func findRunningOutputProcesses() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)

    var running: [AudioObjectID] = []
    for id in ids {
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &isRunning) == noErr,
           isRunning != 0 {
            running.append(id)
        }
    }
    return running
}

final class CaptureBox {
    static var samples: [Float] = []
    static var lock = NSLock()
    static var done = false
}

let processes = findRunningOutputProcesses()
print("running-output processes: \(processes.count)")
guard !processes.isEmpty else {
    print("NOTHING is playing - start Spotify and run again")
    exit(2)
}

// Create the tap over ALL processes (combined mix).
let tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
tapDescription.name = "HTDemucs probe"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
guard status == noErr else {
    print("tap create failed: \(status)")
    exit(1)
}

// Aggregate device hosting the tap.
var tapUIDRef: CFString = "" as CFString
var uidSize = UInt32(MemoryLayout<CFString>.size)
var uidAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUIDRef)
let tapUID = tapUIDRef as String

let aggregateUUID = UUID().uuidString
let aggregateDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "HTDemucs probe aggregate",
    kAudioAggregateDeviceUIDKey: "org.aleccandidato.probe.\(aggregateUUID)",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
    ],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateID)
guard status == noErr else {
    print("aggregate create failed: \(status)")
    exit(1)
}

final class IOBox {
    static var ioProcID: AudioDeviceIOProcID?
    static var aggregateID = AudioObjectID(kAudioObjectUnknown)
}

var ioProcID: AudioDeviceIOProcID?
status = AudioDeviceCreateIOProcIDWithBlock(
    &ioProcID, aggregateID, DispatchQueue(label: "probe.capture")
) { _, inputData, _, _, _ in
    guard !CaptureBox.done else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData)
    )
    CaptureBox.lock.lock()
    for buffer in buffers {
        guard buffer.mDataByteSize > 0, let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let floats = data.assumingMemoryBound(to: Float.self)
        CaptureBox.samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
    }
    let have = CaptureBox.samples.count
    CaptureBox.lock.unlock()
    if have >= captureSamples * 2 { CaptureBox.done = true }
}
guard status == noErr else {
    print("IOProc create failed: \(status)")
    exit(1)
}
IOBox.ioProcID = ioProcID
IOBox.aggregateID = aggregateID

status = AudioDeviceStart(aggregateID, ioProcID!)
guard status == noErr else {
    print("device start failed: \(status)")
    exit(1)
}
print("capturing \(captureSeconds)s of live audio… play something!")

while !CaptureBox.done {
    Thread.sleep(forTimeInterval: 0.2)
    CaptureBox.lock.lock()
    let have = CaptureBox.samples.count
    CaptureBox.lock.unlock()
    print("  captured \(have) samples (\(String(format: "%.1f", Double(have) / 2 / fs))s)")
    if have >= captureSamples * 2 { CaptureBox.done = true }
}
CaptureBox.done = true

AudioDeviceStop(aggregateID, IOBox.ioProcID!)
AudioDeviceDestroyIOProcID(aggregateID, IOBox.ioProcID!)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

CaptureBox.lock.lock()
var captured = CaptureBox.samples
CaptureBox.lock.unlock()

// Keep only stereo-interleaved frames.
let framesAvailable = captured.count / 2
let frames = min(framesAvailable, captureSamples)
captured = Array(captured.prefix(frames * 2))

// Deinterleave to planar L/R.
var leftChannel = [Float](repeating: 0, count: frames)
var rightChannel = [Float](repeating: 0, count: frames)
for i in 0..<frames {
    leftChannel[i] = captured[i * 2]
    rightChannel[i] = captured[i * 2 + 1]
}
print("captured \(frames) frames")

// ---- Separation ----

// The model expects 44.1 kHz; resample 48k -> 44.1k via vDSP.
let ratio = 44100.0 / fs
let outFrames = Int(Double(frames) * ratio)
var resampledL = [Float](repeating: 0, count: outFrames)
var resampledR = [Float](repeating: 0, count: outFrames)
var inputL = leftChannel
var inputR = rightChannel
// Simple linear resample:
for i in 0..<outFrames {
    let srcPos = Double(i) / ratio
    let i0 = min(Int(srcPos), frames - 2)
    let frac = Float(srcPos - Double(i0))
    resampledL[i] = leftChannel[i0] * (1 - frac) + leftChannel[i0 + 1] * frac
    resampledR[i] = rightChannel[i0] * (1 - frac) + rightChannel[i0 + 1] * frac
}

let modelSamples = 441_000

// Normalize the input to a healthy peak level - the official Demucs
// pipeline normalizes before inference; the stateless CoreML conversion
// may have dropped that wrapper.
var maxAbs: Float = 0
for i in 0..<outFrames {
    maxAbs = max(maxAbs, abs(resampledL[i]), abs(resampledR[i]))
}
if maxAbs > 0 {
    let scale = 0.9 / maxAbs
    for i in 0..<outFrames {
        resampledL[i] *= scale
        resampledR[i] *= scale
    }
    print("normalized input by ×\(String(format: "%.2f", scale)) (peak was \(maxAbs))")
}
let modelPackage = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/AlecsNookModels/HTDemucs_CoreML_FP16.mlpackage")
let compiled = try MLModel.compileModel(at: modelPackage)
let config = MLModelConfiguration()
config.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: compiled, configuration: config)

let audio = try MLMultiArray(shape: [1, 2, modelSamples] as [NSNumber], dataType: .float32)
for i in 0..<min(outFrames, modelSamples) {
    audio[[0, 0, i] as [NSNumber]] = NSNumber(value: resampledL[i])
    audio[[0, 1, i] as [NSNumber]] = NSNumber(value: resampledR[i])
}

let input = try MLDictionaryFeatureProvider(
    dictionary: ["audio": MLFeatureValue(multiArray: audio)]
)

print("== running HTDemucs on real music ==")
var inSq = 0.0
for i in 0..<min(outFrames, modelSamples) {
    inSq += Double(resampledL[i]) * Double(resampledL[i])
}
print("input mix rms: \(String(format: "%.4f", sqrt(inSq / Double(max(min(outFrames, modelSamples), 1)))))")
let runStart = Date()
let output = try model.prediction(from: input)
let seconds = -runStart.timeIntervalSinceNow
print("inference: \(String(format: "%.1f", seconds))s")

let sources = try output.featureValue(for: "sources")!.multiArrayValue!
let stemNames = ["vocals", "drums", "bass", "other"]

for stem in 0..<4 {
    var sumSquares = 0.0
    for i in stride(from: 0, to: modelSamples, by: 8) {
        let l = sources[[0, stem, 0, i] as [NSNumber]].doubleValue
        let r = sources[[0, stem, 1, i] as [NSNumber]].doubleValue
        sumSquares += (l * l + r * r) / 2
    }
    let rms = sqrt(sumSquares / Double(modelSamples / 8))
    print("stem \(stem) (\(stemNames[stem])): rms=\(String(format: "%.4f", rms))")
}

// Save ALL stems + the input mix as WAVs for listening.
func writeWav(_ samplesL: [Float], _ samplesR: [Float], to url: URL, sampleRate: Double) throws {
    var header = Data()
    let dataBytes = samplesL.count * 2 * MemoryLayout<Float>.size
    func append(_ value: UInt32) { withUnsafeBytes(of: value) { header.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataBytes))
    header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8))
    append(16); append16(1); append16(2)
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 4)); append16(4); append16(16)
    header.append(contentsOf: Array("data".utf8))
    append(UInt32(dataBytes))
    var samplesData = Data()
    for i in 0..<samplesL.count {
        withUnsafeBytes(of: samplesL[i]) { samplesData.append(contentsOf: $0) }
        withUnsafeBytes(of: samplesR[i]) { samplesData.append(contentsOf: $0) }
    }
    try (header + samplesData).write(to: url)
}

var vocalsL = [Float](repeating: 0, count: modelSamples)
var vocalsR = [Float](repeating: 0, count: modelSamples)
var otherL = [Float](repeating: 0, count: modelSamples)
var otherR = [Float](repeating: 0, count: modelSamples)
for i in 0..<modelSamples {
    vocalsL[i] = sources[[0, 0, 0, i] as [NSNumber]].floatValue
    vocalsR[i] = sources[[0, 0, 1, i] as [NSNumber]].floatValue
    otherL[i] = sources[[0, 3, 0, i] as [NSNumber]].floatValue
    otherR[i] = sources[[0, 3, 1, i] as [NSNumber]].floatValue
}

// Input mix (resampled) for reference.
let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
try writeWav(resampledL, resampledR, to: documents.appendingPathComponent("htdemucs_input_mix.wav"), sampleRate: 44100)

for stem in 0..<4 {
    var stemL = [Float](repeating: 0, count: modelSamples)
    var stemR = [Float](repeating: 0, count: modelSamples)
    for i in 0..<modelSamples {
        stemL[i] = sources[[0, stem, 0, i] as [NSNumber]].floatValue
        stemR[i] = sources[[0, stem, 1, i] as [NSNumber]].floatValue
    }
    try writeWav(
        stemL, stemR,
        to: documents.appendingPathComponent("htdemucs_stem\(stem)_\(stemNames[stem]).wav"),
        sampleRate: 44100
    )
}
print("== WAVs in ~/Documents: input mix + all 4 stems ==")
print("== done — listen and tell me which stem has the vocals ==")
