// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation

public struct WaveAudio: Sendable, Equatable {
    public let sampleRate: Int
    public var samples: [Float]
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
    public init(sampleRate: Int, samples: [Float]) throws {
        guard (1000...192000).contains(sampleRate), !samples.isEmpty,
              samples.count <= sampleRate * 600, samples.count <= 32_000_000, samples.allSatisfy({ $0.isFinite }) else {
            throw PicoFoxError.invalid("Audio must contain finite samples, use 1–192 kHz, be no longer than 10 minutes, and contain at most 32 million working samples.")
        }
        self.sampleRate = sampleRate
        self.samples = samples
    }
    public static func decode(_ data: Data) throws -> WaveAudio {
        let bytes = [UInt8](data)
        func fail() -> PicoFoxError { .invalid("Unsupported or damaged WAV. Import uncompressed PCM (8/16/24/32-bit) or 32-bit float WAV.") }
        guard bytes.count >= 44, bytes.count <= 64_000_000 else { throw fail() }
        func text(_ start: Int, _ count: Int) -> String { String(bytes: bytes[start..<(start + count)], encoding: .ascii) ?? "" }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard text(0, 4) == "RIFF", text(8, 4) == "WAVE", u32(4) + 8 <= bytes.count else { throw fail() }
        let riffEnd = u32(4) + 8
        var format: (kind: Int, channels: Int, rate: Int, bits: Int, align: Int)?
        var payload: Range<Int>?
        var offset = 12
        while offset + 8 <= riffEnd {
            let length = u32(offset + 4)
            let start = offset + 8
            guard length <= riffEnd - start else { throw fail() }
            if text(offset, 4) == "fmt " {
                guard length >= 16 else { throw fail() }
                format = (u16(start), u16(start + 2), u32(start + 4), u16(start + 14), u16(start + 12))
            } else if text(offset, 4) == "data", payload == nil { payload = start..<(start + length) }
            offset = start + length + length % 2
        }
        guard let f = format, let p = payload, (1...8).contains(f.channels), (1000...192000).contains(f.rate),
              (f.kind == 1 && [8,16,24,32].contains(f.bits)) || (f.kind == 3 && f.bits == 32),
              f.align == f.channels * (f.bits / 8), p.count % f.align == 0,
              p.count / f.align <= f.rate * 600, p.count / f.align <= 12_000_000 else { throw fail() }
        var samples = [Float]()
        samples.reserveCapacity(p.count / f.align)
        for frame in stride(from: p.lowerBound, to: p.upperBound, by: f.align) {
            var mono: Float = 0
            for channel in 0..<f.channels {
                let i = frame + channel * (f.bits / 8)
                let value: Float
                if f.kind == 3 { value = Float(bitPattern: UInt32(u32(i))) }
                else {
                    switch f.bits {
                    case 8: value = Float(Int(bytes[i]) - 128) / 128
                    case 16: value = Float(Int16(bitPattern: UInt16(u16(i)))) / 32768
                    case 24:
                        var raw = Int32(bytes[i]) | Int32(bytes[i + 1]) << 8 | Int32(bytes[i + 2]) << 16
                        if raw & 0x800000 != 0 { raw |= ~0xFFFFFF }
                        value = Float(raw) / 8388608
                    default: value = Float(Int32(bitPattern: UInt32(u32(i)))) / 2147483648
                    }
                }
                guard value.isFinite else { throw fail() }
                mono += value / Float(f.channels)
            }
            samples.append(max(-1, min(1, mono)))
        }
        return try WaveAudio(sampleRate: f.rate, samples: samples)
    }

    /// Windowed-sinc conversion with cached polyphase kernels. Common audio rates use exact phases.
    public func resampled(to rate: Int = 5000) throws -> WaveAudio {
        guard (1000...192000).contains(rate) else { throw PicoFoxError.invalid("Invalid target sample rate.") }
        if rate == sampleRate { return self }
        let ratio = Double(rate) / Double(sampleRate)
        let count = max(1, Int((Double(samples.count) * ratio).rounded()))
        guard count <= 32_000_000 else { throw PicoFoxError.invalid("Converted audio is too large.") }
        let cutoff = min(1.0, ratio) * 0.94
        let radius = Int(ceil(20 / cutoff))
        let width = 2 * radius + 1
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(sampleRate, rate)
        let period = rate / divisor
        let phaseLimit = max(1, min(1024, 1_000_000 / width))
        let exact = period <= phaseLimit
        let phaseCount = exact ? period : phaseLimit
        let tableRows = exact ? phaseCount : phaseCount + 1
        var kernels = [Double](repeating: 0, count: tableRows * width)
        for phase in 0..<tableRows {
            try Task.checkCancellation()
            let fraction = Double(phase) / Double(phaseCount)
            for tap in -radius...radius {
                let delta = fraction - Double(tap)
                let x = Double.pi * delta * cutoff
                let sinc = abs(x) < 1e-12 ? 1 : sin(x) / x
                let window = 0.5 + 0.5 * cos(Double.pi * delta / Double(radius + 1))
                kernels[phase * width + tap + radius] = cutoff * sinc * window
            }
        }
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let position = index * sampleRate
            let base = position / rate
            let remainder = position % rate
            let phase = exact ? remainder / divisor : Int((Double(remainder) * Double(phaseCount) / Double(rate)).rounded())
            let lo = max(-radius, -base)
            let hi = min(radius, samples.count - 1 - base)
            var sum = 0.0, weight = 0.0
            for tap in lo...hi {
                let w = kernels[phase * width + tap + radius]
                sum += Double(samples[base + tap]) * w
                weight += w
            }
            // Keep filter overshoot until encoding, where one uniform scale preserves the waveform.
            output[index] = Float(abs(weight) > 1e-12 ? sum / weight : 0)
        }
        return try WaveAudio(sampleRate: rate, samples: output)
    }

    public func edited(start: Double, end: Double, gainDB: Double, normalize: Bool, fadeSeconds: Double) throws -> WaveAudio {
        guard start.isFinite, end.isFinite, gainDB.isFinite, fadeSeconds.isFinite,
              start >= 0, end <= duration + 0.000001, start < end, (-60...24).contains(gainDB), (0...10).contains(fadeSeconds) else {
            throw PicoFoxError.invalid("Choose a nonempty trim range, gain between −60 and +24 dB, and fade between 0 and 10 seconds.")
        }
        let lo = min(samples.count - 1, Int(start * Double(sampleRate)))
        let hi = min(samples.count, max(lo + 1, Int(end * Double(sampleRate))))
        var output = Array(samples[lo..<hi])
        let peak = output.reduce(Float(0)) { max($0, abs($1)) }
        let requestedScale = pow(10, gainDB / 20) * (normalize && peak > 0 ? 0.95 / Double(peak) : 1)
        let scale = peak > 0 ? min(requestedScale, 1 / Double(peak)) : requestedScale
        let fade = min(output.count / 2, Int(fadeSeconds * Double(sampleRate)))
        for i in output.indices {
            let envelope = fade > 0 ? min(1, Double(min(i, output.count - 1 - i)) / Double(fade)) : 1
            output[i] = Float(Double(output[i]) * scale * envelope)
        }
        return try WaveAudio(sampleRate: sampleRate, samples: output)
    }

    /// Canonical PCM16 WAV at this audio's rate; scales overload uniformly instead of clipping peaks.
    public func pcm16WAV() -> Data {
        var result = Data()
        result.reserveCapacity(44 + samples.count * 2)
        func ascii(_ s: String) { result.append(contentsOf: s.utf8) }
        func word(_ n: UInt16) { result.append(UInt8(n & 255)); result.append(UInt8(n >> 8)) }
        func dword(_ n: UInt32) { word(UInt16(n & 65535)); word(UInt16(n >> 16)) }
        let length = UInt32(samples.count * 2)
        ascii("RIFF"); dword(36 + length); ascii("WAVEfmt "); dword(16)
        word(1); word(1); dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 2)); word(2); word(16)
        ascii("data"); dword(length)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let scale = peak > 1 ? 1 / Double(peak) : 1
        result.count = 44 + samples.count * 2
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, sample) in samples.enumerated() {
                let value = Int16(max(-32768, min(32767, Int((Double(sample) * scale * 32767).rounded()))))
                let bits = UInt16(bitPattern: value)
                bytes[44 + index * 2] = UInt8(bits & 255)
                bytes[45 + index * 2] = UInt8(bits >> 8)
            }
        }
        return result
    }

    /// Device files stay at the firmware's 5 kHz rate and fixed 44-byte header.
    public func picoFoxWAV() throws -> Data { try resampled().pcm16WAV() }

    /// Hardware playback uses a standard 48 kHz stream. Radio audition keeps the 5 kHz bandwidth.
    public func previewWAV(radio: Bool = false) throws -> Data {
        let audition = radio ? try resampled() : self
        return try audition.resampled(to: 48000).pcm16WAV()
    }

    public func peaks(buckets: Int = 240) -> [Float] {
        let count = min(max(1, buckets), samples.count)
        return (0..<count).map { i in
            let lo = i * samples.count / count
            let hi = (i + 1) * samples.count / count
            return samples[lo..<hi].reduce(0) { max($0, abs($1)) }
        }
    }
    public static func tone(hz: Double = 600, seconds: Double = 3, sampleRate: Int = 48000) throws -> WaveAudio {
        guard hz.isFinite, seconds.isFinite, (100...2000).contains(hz), (0.1...60).contains(seconds), (5000...192000).contains(sampleRate) else { throw PicoFoxError.invalid("Tone must be 100–2000 Hz and 0.1–60 seconds.") }
        let count = Int(seconds * Double(sampleRate))
        let ramp = min(count / 2, Int(0.005 * Double(sampleRate)))
        var output = [Float]()
        output.reserveCapacity(count)
        for index in 0..<count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let edge = Double(min(index, count - 1 - index)) / Double(max(1, ramp))
            let envelope = edge >= 1 ? 1 : 0.5 - 0.5 * cos(.pi * edge)
            output.append(Float(sin(2 * .pi * hz * Double(index) / Double(sampleRate)) * 0.5 * envelope))
        }
        return try WaveAudio(sampleRate: sampleRate, samples: output)
    }
}
