// clap-calibrate.swift
//
// Records 20 seconds from the system default input device while the user
// claps 10 times. For each detected transient (a sharp amplitude spike), it
// logs:
//   timestamp, peak amplitude, RMS, ratio-vs-noise-floor, low-band energy,
//   high-band energy, high/low ratio
//
// At the end, dumps a CSV and a WAV. The CSV lets us pick a threshold
// (peak / ratio / spectral) that separates real claps from speech/noise.
// The WAV lets us listen back to verify nothing weird is happening at the
// CoreAudio layer.
//
// Usage:
//   ./clap-calibrate <output-dir>
//
// Build:
//   swiftc clap-calibrate.swift -o clap-calibrate \
//     -framework AVFoundation -framework Foundation -framework CoreAudio

import Foundation
import AVFoundation
import CoreAudio
import Accelerate

let RECORD_SECONDS: TimeInterval = 20.0

// Detector parameters. Two layers: a permissive CANDIDATE filter (so we log
// every plausible transient for analysis), and a strict CLAP classifier
// applied on top of each candidate (these are the values we'd actually use
// in the listener).
let CLAP_PEAK_THRESHOLD: Float = 0.10
let CLAP_RATIO_THRESHOLD: Float = 6.0
let CLAP_REFRACTORY: TimeInterval = 0.10

// Strict thresholds for "is this a real clap?"
let STRICT_PEAK: Float = 0.25
let STRICT_RATIO: Float = 100.0
let STRICT_HL_MAX: Float = 0.85     // hl_ratio above this looks vocal
let STRICT_REFRACTORY: TimeInterval = 0.5

let outDir: String
if CommandLine.arguments.count >= 2 {
    outDir = CommandLine.arguments[1]
} else {
    outDir = NSHomeDirectory() + "/.claude/skills/talk/clap-calibration"
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let csvPath = "\(outDir)/transients-\(ts).csv"
let wavPath = "\(outDir)/recording-\(ts).wav"
print("calibrator: writing to \(outDir)")
print("  csv: \(csvPath)")
print("  wav: \(wavPath)")

// MARK: - Detector state

var noiseFloor: Float = 0.005
var lastTransient: Date = .distantPast
var lastStrictClap: Date = .distantPast
var startedAt: Date = Date()
var strictClapCount: Int = 0
var rejectCount: Int = 0

struct TransientEvent {
    let tSec: Double
    let peak: Float
    let rms: Float
    let ratio: Float
    let lowEnergy: Float   // energy in 0–2kHz band
    let highEnergy: Float  // energy in 2kHz+ band
    var hlRatio: Float { highEnergy / max(lowEnergy, 1e-9) }
}

var events: [TransientEvent] = []

// MARK: - Spectral split: low-band vs high-band energy via 1024-pt FFT

let fftLog2N: vDSP_Length = 10        // 2^10 = 1024
let fftSize: Int = 1 << fftLog2N
let fftSetup = vDSP_create_fftsetup(fftLog2N, FFTRadix(kFFTRadix2))!

func bandEnergies(samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> (low: Float, high: Float) {
    let n = min(count, fftSize)
    var window = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

    var windowed = [Float](repeating: 0, count: fftSize)
    // Zero-pad if shorter
    var input = [Float](repeating: 0, count: fftSize)
    for i in 0..<n { input[i] = samples[i] }
    vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

    var realp = [Float](repeating: 0, count: fftSize / 2)
    var imagp = [Float](repeating: 0, count: fftSize / 2)
    var split = DSPSplitComplex(realp: &realp, imagp: &imagp)

    windowed.withUnsafeBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cptr in
            vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(fftSize / 2))
        }
    }

    vDSP_fft_zrip(fftSetup, &split, 1, fftLog2N, FFTDirection(FFT_FORWARD))

    var mag = [Float](repeating: 0, count: fftSize / 2)
    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(fftSize / 2))

    let nyquist = sampleRate / 2
    let binHz = nyquist / Float(fftSize / 2)
    let splitBin = Int(2000.0 / binHz)
    var low: Float = 0
    var high: Float = 0
    for i in 0..<(fftSize / 2) {
        let v = mag[i] * mag[i]
        if i < splitBin { low += v } else { high += v }
    }
    return (low, high)
}

// MARK: - Pin system default input to a real mic (DJI > MacBook > Built-in)
// Same approach as voice-listener.swift — touching inputNode.audioUnit on
// macOS 26 breaks audio capture, so we set the system default instead.

func findInputDeviceMatching(_ needle: String) -> AudioDeviceID? {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
    for dev in devices {
        var inSize: UInt32 = 0
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(dev, &inAddr, 0, nil, &inSize)
        if inSize == 0 { continue }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &nameRef) { p -> OSStatus in
            AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, p)
        }
        if st != noErr { continue }
        if (nameRef as String).localizedCaseInsensitiveContains(needle) { return dev }
    }
    return nil
}

func getDefaultInput() -> AudioDeviceID? {
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return st == noErr ? dev : nil
}

func setDefaultInput(_ id: AudioDeviceID) -> Bool {
    var dev = id
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &dev
    ) == noErr
}

let originalInput = getDefaultInput()
let candidates = ["Wireless Microphone", "DJI", "MacBook", "Built-in"]
var pickedID: AudioDeviceID? = nil
var pickedName = ""
for n in candidates {
    if let id = findInputDeviceMatching(n) {
        pickedID = id; pickedName = n; break
    }
}
if let id = pickedID {
    if setDefaultInput(id) {
        print("calibrator: pinned input to '\(pickedName)' (id=\(id))")
    } else {
        print("calibrator: WARN could not set default input")
    }
} else {
    print("calibrator: WARN no preferred input found; using whatever the system default is")
}

// MARK: - Audio engine setup (mirror voice-listener.swift)

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.inputFormat(forBus: 0)
let sampleRate = Float(format.sampleRate)

print("calibrator: input format sr=\(format.sampleRate) ch=\(format.channelCount)")

// WAV writer — write whole recording at end as 32-bit float mono.
var allSamples: [Float] = []

input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let chan = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    if frames == 0 { return }
    let samples = chan[0]

    // Append to the master buffer (downmix to mono just by taking ch0).
    for i in 0..<frames { allSamples.append(samples[i]) }

    // Detector: compute per-buffer peak and RMS.
    var sumSquares: Float = 0
    var peak: Float = 0
    for i in 0..<frames {
        let s = samples[i]
        sumSquares += s * s
        let mag = abs(s)
        if mag > peak { peak = mag }
    }
    let rms = sqrt(sumSquares / Float(frames))

    if peak < noiseFloor * 4 {
        noiseFloor = noiseFloor * 0.98 + rms * 0.02
        if noiseFloor < 0.001 { noiseFloor = 0.001 }
    }

    let ratio = peak / max(noiseFloor, 0.0005)
    let now = Date()

    if peak >= CLAP_PEAK_THRESHOLD &&
       ratio >= CLAP_RATIO_THRESHOLD &&
       now.timeIntervalSince(lastTransient) >= CLAP_REFRACTORY {
        lastTransient = now
        let bands = bandEnergies(samples: samples, count: frames, sampleRate: sampleRate)
        let ev = TransientEvent(
            tSec: now.timeIntervalSince(startedAt),
            peak: peak,
            rms: rms,
            ratio: ratio,
            lowEnergy: bands.low,
            highEnergy: bands.high
        )
        events.append(ev)
        let dt = String(format: "%.2f", ev.tSec)

        // Apply strict classifier on top.
        let passesStrict =
            peak >= STRICT_PEAK &&
            ratio >= STRICT_RATIO &&
            ev.hlRatio <= STRICT_HL_MAX &&
            now.timeIntervalSince(lastStrictClap) >= STRICT_REFRACTORY
        let label: String
        if passesStrict {
            label = "CLAP"
            lastStrictClap = now
            strictClapCount += 1
        } else {
            label = "REJECT"
            rejectCount += 1
        }
        let reason: String
        if passesStrict {
            reason = ""
        } else {
            var rs: [String] = []
            if peak < STRICT_PEAK { rs.append("peak<\(STRICT_PEAK)") }
            if ratio < STRICT_RATIO { rs.append("ratio<\(STRICT_RATIO)") }
            if ev.hlRatio > STRICT_HL_MAX { rs.append("hl>\(STRICT_HL_MAX)") }
            if now.timeIntervalSince(lastStrictClap) < STRICT_REFRACTORY { rs.append("refrac") }
            reason = " (" + rs.joined(separator: ",") + ")"
        }
        print("  [\(label)] @\(dt)s peak=\(String(format: "%.3f", peak)) ratio=\(String(format: "%.1f", ratio)) hl=\(String(format: "%.2f", ev.hlRatio))\(reason)")
    }
}

engine.prepare()
do {
    try engine.start()
} catch {
    print("audio engine start failed: \(error)")
    exit(1)
}

print("")
print("==========================================")
print("CLAP CALIBRATION — recording for \(Int(RECORD_SECONDS))s")
print("Clap 10 times, naturally paced, varying intensity.")
print("Optionally also speak loudly / shout once to capture false-positive samples.")
print("==========================================")
startedAt = Date()

RunLoop.main.run(until: Date(timeIntervalSinceNow: RECORD_SECONDS))
engine.stop()

print("")
print("==========================================")
print("DONE — \(events.count) candidates, classified as \(strictClapCount) CLAP / \(rejectCount) REJECT")
print("strict thresholds: peak>=\(STRICT_PEAK), ratio>=\(STRICT_RATIO), hl<=\(STRICT_HL_MAX), refrac=\(STRICT_REFRACTORY)s")

// MARK: - Write CSV

var csv = "t_sec,peak,rms,ratio,low_energy,high_energy,high_low_ratio\n"
for ev in events {
    csv += "\(String(format: "%.3f", ev.tSec)),"
    csv += "\(String(format: "%.5f", ev.peak)),"
    csv += "\(String(format: "%.5f", ev.rms)),"
    csv += "\(String(format: "%.3f", ev.ratio)),"
    csv += "\(String(format: "%.3f", ev.lowEnergy)),"
    csv += "\(String(format: "%.3f", ev.highEnergy)),"
    csv += "\(String(format: "%.3f", ev.hlRatio))\n"
}
try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)

// MARK: - Write WAV (32-bit float mono)

func writeWAV(samples: [Float], sampleRate: Float, path: String) {
    let bitsPerSample: UInt16 = 32
    let channels: UInt16 = 1
    let byteRate = UInt32(Float(channels) * Float(bitsPerSample / 8) * sampleRate)
    let blockAlign: UInt16 = channels * (bitsPerSample / 8)
    let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
    let chunkSize = 36 + dataSize

    var d = Data()
    d.append("RIFF".data(using: .ascii)!)
    var v32 = chunkSize.littleEndian; d.append(Data(bytes: &v32, count: 4))
    d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!)
    var fmtSize: UInt32 = 16; d.append(Data(bytes: &fmtSize, count: 4))
    var audioFormat: UInt16 = 3 /* IEEE float */; d.append(Data(bytes: &audioFormat, count: 2))
    var ch = channels; d.append(Data(bytes: &ch, count: 2))
    var sr = UInt32(sampleRate); d.append(Data(bytes: &sr, count: 4))
    var br = byteRate; d.append(Data(bytes: &br, count: 4))
    var ba = blockAlign; d.append(Data(bytes: &ba, count: 2))
    var bps = bitsPerSample; d.append(Data(bytes: &bps, count: 2))
    d.append("data".data(using: .ascii)!)
    var ds = dataSize; d.append(Data(bytes: &ds, count: 4))
    samples.withUnsafeBufferPointer { ptr in
        d.append(UnsafeBufferPointer(start: ptr.baseAddress, count: samples.count))
    }
    try? d.write(to: URL(fileURLWithPath: path))
}

writeWAV(samples: allSamples, sampleRate: sampleRate, path: wavPath)

// MARK: - Stats

if !events.isEmpty {
    let peaks = events.map { $0.peak }
    let ratios = events.map { $0.ratio }
    let hls = events.map { $0.hlRatio }
    func stats(_ a: [Float]) -> (Float, Float, Float, Float) {
        let s = a.sorted()
        let avg = a.reduce(0, +) / Float(a.count)
        return (s.first!, s[s.count / 2], avg, s.last!)
    }
    let (pmin, pmed, pavg, pmax) = stats(peaks)
    let (rmin, rmed, ravg, rmax) = stats(ratios)
    let (hmin, hmed, havg, hmax) = stats(hls)
    print("peak     min=\(String(format: "%.3f", pmin)) med=\(String(format: "%.3f", pmed)) avg=\(String(format: "%.3f", pavg)) max=\(String(format: "%.3f", pmax))")
    print("ratio    min=\(String(format: "%.1f", rmin)) med=\(String(format: "%.1f", rmed)) avg=\(String(format: "%.1f", ravg)) max=\(String(format: "%.1f", rmax))")
    print("hl_ratio min=\(String(format: "%.2f", hmin)) med=\(String(format: "%.2f", hmed)) avg=\(String(format: "%.2f", havg)) max=\(String(format: "%.2f", hmax))")
} else {
    print("no transients detected — CLAP_PEAK_THRESHOLD may be too high")
}

print("")
// Restore the user's prior default input device.
if let prev = originalInput, prev != 0 {
    _ = setDefaultInput(prev)
}

print("CSV: \(csvPath)")
print("WAV: \(wavPath)")
print("==========================================")
