#!/usr/bin/env swift
// Synthesizes Shelf's sound effects, so the app ships no third-party audio.
// Run from the repository root:
//   swift Scripts/generate-sounds.swift                  writes Resources/Sounds/Paste.wav and Copy.wav
//   swift Scripts/generate-sounds.swift <folder> --all   writes every variant, to audition
import Foundation

/// A pop: a sine whose pitch moves fast from `startHz` to `endHz` (falling for
/// the paste pop, rising for the copy tick), with a
/// near-instant attack and an exponential decay, plus a faint low-passed click
/// for the "p". It stays above about 500 Hz, because laptop speakers barely
/// play anything lower; overtones keep it round rather than shrill.
struct Pop {
    var name: String
    var startHz: Double
    var endHz: Double
    /// How fast the pitch falls, in seconds.
    var pitchTime: Double
    /// How fast the sound dies away, in seconds.
    var decayTime: Double
    var duration = 0.2
    var click = 0.18
    /// Second and third harmonics, relative to the fundamental.
    var warmth = 0.35
    var body = 0.12

    func samples(rate: Double) -> [Double] {
        let count = Int(duration * rate)
        var output = [Double](repeating: 0, count: count)
        var phase = 0.0
        var noise: UInt64 = 0x2545_F491_4F6C_DD1D // fixed seed: the same file every run
        var lowPassed = 0.0
        for index in 0..<count {
            let time = Double(index) / rate
            let frequency = endHz + (startHz - endHz) * exp(-time / pitchTime)
            phase += 2 * .pi * frequency / rate
            let attack = min(1, time / 0.0015)
            let envelope = attack * exp(-time / decayTime)
            let tone = sin(phase) + warmth * sin(2 * phase) + body * sin(3 * phase)

            noise ^= noise << 13
            noise ^= noise >> 7
            noise ^= noise << 17
            let white = Double(noise % 2_000_001) / 1_000_000 - 1
            lowPassed += 0.25 * (white - lowPassed)
            let transient = click * lowPassed * exp(-time / 0.0009)

            let fadeOut = min(1, (duration - time) / 0.012)
            output[index] = (tone * envelope + transient) * fadeOut
        }
        let peak = output.map(abs).max() ?? 1
        return output.map { $0 / peak * 0.7 }
    }
}

let variants = [
    Pop(name: "Paste-soft", startHz: 1_050, endHz: 460, pitchTime: 0.012, decayTime: 0.050),
    Pop(name: "Paste", startHz: 1_300, endHz: 560, pitchTime: 0.010, decayTime: 0.045),
    Pop(name: "Paste-bright", startHz: 1_700, endHz: 720, pitchTime: 0.009, decayTime: 0.038),
    // Rising and shorter, so a copy and a paste are told apart by ear.
    Pop(name: "Copy", startHz: 640, endHz: 1_250, pitchTime: 0.018, decayTime: 0.028, duration: 0.14, click: 0.1),
]

/// 16-bit mono PCM WAV.
func wav(_ samples: [Double], rate: Int) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1)) // PCM
    append(UInt16(1)) // mono
    append(UInt32(rate))
    append(UInt32(rate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(byteCount))
    for sample in samples {
        append(Int16(max(-1, min(1, sample)) * Double(Int16.max)))
    }
    return data
}

let arguments = CommandLine.arguments.dropFirst()
let folder = URL(fileURLWithPath: arguments.first { !$0.hasPrefix("--") } ?? "Resources/Sounds", isDirectory: true)
let chosen = arguments.contains("--all") ? variants : variants.filter { ["Paste", "Copy"].contains($0.name) }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let rate = 44_100
for pop in chosen {
    let url = folder.appendingPathComponent("\(pop.name).wav")
    try wav(pop.samples(rate: Double(rate)), rate: rate).write(to: url)
    print("Wrote \(url.path)")
}
