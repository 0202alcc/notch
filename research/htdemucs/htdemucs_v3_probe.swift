// Probe v3: capture -> proper resample -> demucs normalization ->
// chunked inference (2.5s overlap OLA + 2-shift averaging) ->
// vocals stem; instrumental = mix - vocals (exact conservation).
// Usage: htdemucs_v3_probe [FP16|FP32]
import CoreML
import Foundation
import AVFoundation
import CoreAudio

setvbuf(stdout, nil, _IONBF, 0)

let fs = 48000.0
let targetRate = 44100.0
let captureSeconds = 12.0
let captureSamples = Int(captureSeconds * fs)

let modelVariant = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "FP16"
let modelPackage = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
        modelVariant == "FP32"
            ? "Library/Caches/AlecsNookModels/HTDemucs_CoreML.mlpackage"
            : "Library/Caches/AlecsNookModels/HTDemucs_CoreML_FP16.mlpackage"
    )
print("model: \(modelVariant)")

// ---- Capture ----

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

let tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
tapDescription.name = "HTDemucs probe"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
guard status == noErr else { print("tap create failed: \(status)"); exit(1) }

var tapUIDRef: CFString = "" as CFString
var uidSize = UInt32(MemoryLayout<CFString>.size)
var uidAddr = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUIDRef)
let tapUID = tapUIDRef as String

let aggregateDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "HTDemucs probe aggregate",
    kAudioAggregateDeviceUIDKey: "org.aleccandidato.probe.\(UUID().uuidString)",
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
guard status == noErr else { print("aggregate failed: \(status)"); exit(1) }

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
        CaptureBox.samples.append(contentsOf: UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: count
        ))
    }
    CaptureBox.lock.unlock()
    if CaptureBox.samples.count >= captureSamples * 2 { CaptureBox.done = true }
}
guard status == noErr else { print("IOProc failed: \(status)"); exit(1) }

status = AudioDeviceStart(aggregateID, ioProcID!)
guard status == noErr else { print("start failed: \(status)"); exit(1) }
print("capturing \(captureSeconds)s… keep the music playing!")

while !CaptureBox.done {
    Thread.sleep(forTimeInterval: 0.3)
    CaptureBox.lock.lock()
    if CaptureBox.samples.count >= captureSamples * 2 { CaptureBox.done = true }
    CaptureBox.lock.unlock()
}
CaptureBox.done = true

AudioDeviceStop(aggregateID, ioProcID!)
AudioDeviceDestroyIOProcID(aggregateID, ioProcID!)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

CaptureBox.lock.lock()
let captured = Array(CaptureBox.samples.prefix(captureSamples * 2))
CaptureBox.lock.unlock()

let frames48k = captured.count / 2
print("captured \(frames48k) frames @48k")

// ---- Resample via AVAudioConverter ----

let format48 = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: false
)!
let format44 = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 2, interleaved: false
)!

let inputBuffer = AVAudioPCMBuffer(pcmFormat: format48, frameCapacity: AVAudioFrameCount(frames48k))!
inputBuffer.frameLength = AVAudioFrameCount(frames48k)
for i in 0..<frames48k {
    inputBuffer.floatChannelData![0][i] = captured[i * 2]
    inputBuffer.floatChannelData![1][i] = captured[i * 2 + 1]
}

guard let converter = AVAudioConverter(from: format48, to: format44) else {
    print("no converter"); exit(1)
}
let outCapacity = AVAudioFrameCount(Double(frames48k) * targetRate / fs) + 4096
let outputBuffer = AVAudioPCMBuffer(pcmFormat: format44, frameCapacity: outCapacity)!
var consumed = false
var conversionError: NSError?
converter.convert(to: outputBuffer, error: &conversionError) { _, status in
    if consumed { status.pointee = .endOfStream; return nil }
    consumed = true
    status.pointee = .haveData
    return inputBuffer
}
if let conversionError { print("convert error: \(conversionError)"); exit(1) }

let outFrames = Int(outputBuffer.frameLength)
let resampledL = Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: outFrames))
let resampledR = Array(UnsafeBufferPointer(start: outputBuffer.floatChannelData![1], count: outFrames))
print("resampled to \(outFrames) frames @44.1k")

// ---- Demucs normalization ----

var mixRef = [Float](repeating: 0, count: outFrames)
var sum: Float = 0
var sumSq: Float = 0
for i in 0..<outFrames {
    mixRef[i] = (resampledL[i] + resampledR[i]) / 2
    sum += mixRef[i]
    sumSq += mixRef[i] * mixRef[i]
}
let mean = sum / Float(outFrames)
let variance = sumSq / Float(outFrames) - mean * mean
let std = max(sqrt(max(variance, 0)), 1e-5)

var normL = [Float](repeating: 0, count: outFrames)
var normR = [Float](repeating: 0, count: outFrames)
for i in 0..<outFrames {
    normL[i] = (resampledL[i] - mean) / std
    normR[i] = (resampledR[i] - mean) / std
}

// ---- Chunked inference: 2.5s overlap OLA + 2-shift averaging ----

let modelSamples = 441_000
let overlapSamples = modelSamples / 4   // 2.5s - the official default
let hopSamples = modelSamples - overlapSamples
let shifts = 2

let compiled = try MLModel.compileModel(at: modelPackage)
let config = MLModelConfiguration()
config.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: compiled, configuration: config)

let chunks = max(1, Int(ceil(Double(outFrames) / Double(hopSamples))))
print("== \(chunks) chunks × \(shifts) shifts ==")

var vocalsAccum = [Float](repeating: 0, count: outFrames * 2)
var shiftWeight = [Float](repeating: 0, count: outFrames)

var window = [Float](repeating: 1, count: modelSamples)
let fadeSamples = overlapSamples
for i in 0..<fadeSamples {
    let x = Float(Double(i) / Double(fadeSamples))
    window[i] = x
    window[modelSamples - 1 - i] = x
}

let chunkStart = Date()
for shift in 0..<shifts {
    let offset = (shift * modelSamples / 2) % outFrames

    for chunk in 0..<chunks {
        let start = chunk * hopSamples
        let array = try MLMultiArray(shape: [1, 2, modelSamples] as [NSNumber], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: modelSamples * 2)
        for f in 0..<modelSamples {
            let g = (start + f + offset) % outFrames
            ptr[f] = normL[g]
            ptr[modelSamples + f] = normR[g]
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: array)]
        )
        let output = try model.prediction(from: input)
        let sources = output.featureValue(for: "sources")!.multiArrayValue!
        let srcPtr = sources.dataPointer.bindMemory(to: Float.self, capacity: 4 * 2 * modelSamples)

        // Only the VOCALS stem is needed - the instrumental is the residual.
        for f in 0..<modelSamples {
            let g = (start + f + offset) % outFrames
            let w = window[f]
            vocalsAccum[g * 2] += srcPtr[f] * w
            vocalsAccum[g * 2 + 1] += srcPtr[modelSamples + f] * w
            if shift == 0 { shiftWeight[g] += w }
        }
    }
}
let inference = -chunkStart.timeIntervalSinceNow
print("inference total: \(String(format: "%.2f", inference))s (RTF \(String(format: "%.2f", inference / (Double(outFrames) / targetRate))))")

// Average over shifts, de-normalize.
var vocalsL = [Float](repeating: 0, count: outFrames)
var vocalsR = [Float](repeating: 0, count: outFrames)
var instL = [Float](repeating: 0, count: outFrames)
var instR = [Float](repeating: 0, count: outFrames)

var residualSq = 0.0
var mixSq = 0.0
for i in 0..<outFrames {
    let w = max(shiftWeight[i], 1e-6)
    let vL = vocalsAccum[i * 2] / w * std + mean
    let vR = vocalsAccum[i * 2 + 1] / w * std + mean
    vocalsL[i] = vL
    vocalsR[i] = vR
    // Instrumental = the residual: conservation is exact by construction.
    instL[i] = resampledL[i] - vL
    instR[i] = resampledR[i] - vR

    let resid = (resampledL[i] - vL - instL[i]) + (resampledR[i] - vR - instR[i])
    residualSq += Double(resid * resid)
    mixSq += Double(resampledL[i] * resampledL[i] + resampledR[i] * resampledR[i])
}
print("conservation residual rms: \(String(format: "%.6f", sqrt(residualSq / Double(outFrames)))) (should be ~0)")

// ---- Write ----

func writeWav(_ l: [Float], _ r: [Float], to url: URL, sampleRate: Double) throws {
    var header = Data()
    let dataBytes = l.count * 2 * MemoryLayout<Float>.size
    func append(_ v: UInt32) { withUnsafeBytes(of: v) { header.append(contentsOf: $0) } }
    func append16(_ v: UInt16) { withUnsafeBytes(of: v) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataBytes))
    header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8))
    append(16); append16(1); append16(2)
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 4)); append16(4); append16(16)
    header.append(contentsOf: Array("data".utf8))
    append(UInt32(dataBytes))
    var samples = Data()
    for i in 0..<l.count {
        withUnsafeBytes(of: l[i]) { samples.append(contentsOf: $0) }
        withUnsafeBytes(of: r[i]) { samples.append(contentsOf: $0) }
    }
    try (header + samples).write(to: url)
}

let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let suffix = "_\(modelVariant.lowercased())"
try writeWav(resampledL, resampledR, to: documents.appendingPathComponent("htdemucs_input_mix.wav"), sampleRate: targetRate)
try writeWav(vocalsL, vocalsR, to: documents.appendingPathComponent("htdemucs_vocals\(suffix).wav"), sampleRate: targetRate)
try writeWav(instL, instR, to: documents.appendingPathComponent("htdemucs_instrumental\(suffix).wav"), sampleRate: targetRate)
print("== WAVs in ~/Documents (suffix \(suffix)) — listen: vocals-only quality + vocals+instrumental vs mix ==")
