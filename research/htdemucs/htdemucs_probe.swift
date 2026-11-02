// M1 feasibility probe: HTDemucs CoreML - compile, infer, measure.
// Validation signal: a 660 Hz sine panned CENTER (should land in the
// vocals stem), a 440 Hz sine hard-LEFT and an 880 Hz sine hard-RIGHT
// (should land in drums/bass/other stems).
import CoreML
import Foundation
import Accelerate

setvbuf(stdout, nil, _IONBF, 0)

let packageURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/AlecsNookModels/HTDemucs_CoreML_FP16.mlpackage")

print("== compiling model (one-time) ==")
let compileStart = Date()
let compiledURL = try MLModel.compileModel(at: packageURL)
print("compiled in \(String(format: "%.1f", -compileStart.timeIntervalSinceNow))s -> \(compiledURL.lastPathComponent)")

let config = MLModelConfiguration()
config.computeUnits = .cpuAndGPU
let loadStart = Date()
let model = try MLModel(contentsOf: compiledURL, configuration: config)
print("loaded in \(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

// Input: (1, 2, 441000) Float32.
let segmentSamples = 441_000
let inputShape = [1, 2, segmentSamples] as [NSNumber]
guard
    let inputDesc = model.modelDescription.inputDescriptionsByName["audio"]
else {
    print("no 'audio' input description")
    exit(1)
}
print("input: \(inputDesc.multiArrayConstraint?.shape.map { $0.intValue } ?? [])")

let audio = try MLMultiArray(shape: inputShape, dataType: .float32)
// Synthetic mix: center 660 Hz ("vocal"), L-only 440 Hz, R-only 880 Hz.
let fs = 44100.0
for i in 0..<segmentSamples {
    let t = Double(i) / fs
    let center = 0.3 * sin(2 * .pi * 660 * t)
    let leftTone = 0.3 * sin(2 * .pi * 440 * t)
    let rightTone = 0.3 * sin(2 * .pi * 880 * t)
    audio[[0, 0, i] as [NSNumber]] = NSNumber(value: center + leftTone)
    audio[[0, 1, i] as [NSNumber]] = NSNumber(value: center + rightTone)
}
print("input filled")

let input = try MLDictionaryFeatureProvider(
    dictionary: ["audio": MLFeatureValue(multiArray: audio)]
)

print("== cold inference ==")
var runStart = Date()
let coldOutput = try model.prediction(from: input)
let coldSeconds = -runStart.timeIntervalSinceNow
print("cold: \(String(format: "%.1f", coldSeconds))s for 10s of audio (RTF \(String(format: "%.2f", coldSeconds / 10)))")

print("== warm inference ==")
runStart = Date()
let output = try model.prediction(from: input)
let warmSeconds = -runStart.timeIntervalSinceNow
print("warm: \(String(format: "%.1f", warmSeconds))s for 10s of audio (RTF \(String(format: "%.2f", warmSeconds / 10)))")

// Analyze the stems: per-stem RMS + dominant frequency via a crude
// zero-crossing-free approach: correlate each stem against each input
// tone to see which tone each stem captured.
let sources = try output.featureValue(for: "sources")!.multiArrayValue!
print("output shape: \(sources.shape.map { $0.intValue })")

let stemNames = ["vocals", "drums", "bass", "other"]
let testFreqs = [660.0, 440.0, 880.0]

for stem in 0..<4 {
    var energies: [Double] = []
    for toneHz in testFreqs {
        var dot = 0.0
        var energy = 0.0
        for i in stride(from: 0, to: segmentSamples, by: 16) {
            let t = Double(i) / fs
            let ref = sin(2 * .pi * toneHz * t)
            let sample = sources[[0, stem, 0, i] as [NSNumber]].doubleValue
            dot += ref * sample
            energy += ref * ref
        }
        // Normalized correlation magnitude (rough dominance measure).
        energies.append(abs(dot) / max(energy, 1e-9) * 2)
    }
    let rms = (0..<segmentSamples).reduce(0.0) { acc, i in
        let v = sources[[0, stem, 0, i] as [NSNumber]].doubleValue
        return acc + v * v
    } / Double(segmentSamples)

    print(
        "stem \(stem) (\(stemNames[stem])): rms=\(String(format: "%.4f", sqrt(rms))) "
        + "correlations center/440/880 = \(energies.map { String(format: "%.2f", $0) }.joined(separator: "/"))"
    )
}
print("== done ==")
