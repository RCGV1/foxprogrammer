// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import Foundation
import PicoFoxCore

/// Apple preview conversion; device export continues to use the portable audio core.
enum AudioPreview: Sendable {
    private static let maximumFrames = 32_000_000
    private static let playbackRate = 48_000

    nonisolated static func render(_ audio: WaveAudio, radio: Bool) throws -> Data {
        try Task.checkCancellation()
        guard (1_000...192_000).contains(audio.sampleRate), !audio.samples.isEmpty,
              audio.samples.count <= maximumFrames, audio.duration <= 600 else {
            throw PicoFoxError.invalid("Audio exceeds the supported preview size or duration.")
        }
        let targetFrames = try frameCount(audio.samples.count, from: audio.sampleRate, to: playbackRate)
        let samples: [Float]
        if radio {
            let radioFrames = try frameCount(audio.samples.count, from: audio.sampleRate, to: 5_000)
            let narrowed = try convert(audio.samples, from: audio.sampleRate, to: 5_000, count: radioFrames)
            samples = try convert(narrowed, from: 5_000, to: playbackRate, count: targetFrames)
        } else {
            samples = try convert(audio.samples, from: audio.sampleRate, to: playbackRate, count: targetFrames)
        }
        return try encode(samples)
    }

    nonisolated private static func frameCount(_ count: Int, from sourceRate: Int, to targetRate: Int) throws -> Int {
        let frames = max(1, Int((Double(count) * Double(targetRate) / Double(sourceRate)).rounded()))
        guard frames <= maximumFrames else { throw PicoFoxError.invalid("Converted audio is too large.") }
        return frames
    }

    nonisolated private static func convert(_ samples: [Float], from sourceRate: Int, to targetRate: Int,
                                            count expectedFrames: Int) throws -> [Float] {
        try Task.checkCancellation()
        if sourceRate == targetRate { return samples }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceRate), channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(min(4_096, expectedFrames))) else {
            throw PicoFoxError.invalid("Audio preview conversion could not be prepared.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.primeMethod = .normal
        let input = try Input(samples: samples, format: inputFormat)
        var result = [Float]()
        result.reserveCapacity(expectedFrames)
        var idlePasses = 0
        while result.count < expectedFrames {
            try Task.checkCancellation()
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                input.provide(requested: requested, status: status)
            }
            if input.wasCancelled { throw CancellationError() }
            if let error { throw error }
            guard status != .error else { throw PicoFoxError.invalid("Audio preview conversion failed.") }
            let produced = min(Int(output.frameLength), expectedFrames - result.count)
            if produced > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
                idlePasses = 0
            } else { idlePasses += 1 }
            if status == .endOfStream { break }
            guard idlePasses < 3 else { throw PicoFoxError.invalid("Audio preview conversion stopped producing samples.") }
        }
        try Task.checkCancellation()
        // The 5 kHz intermediate can round by half a radio frame. Keep the original
        // selection's duration, padding or truncating only its final edge as needed.
        if result.count < expectedFrames {
            result.append(contentsOf: repeatElement(0, count: expectedFrames - result.count))
        }
        return result
    }

    nonisolated private static func encode(_ samples: [Float]) throws -> Data {
        var peak: Float = 0
        for index in samples.indices {
            if index % 16_384 == 0 { try Task.checkCancellation() }
            guard samples[index].isFinite else { throw PicoFoxError.invalid("Audio preview contains an invalid sample.") }
            peak = max(peak, abs(samples[index]))
        }
        let scale = peak > 1 ? 1 / Double(peak) : 1
        var result = Data(count: 44 + samples.count * 2)
        try result.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            func text(_ value: String, at offset: Int) {
                for (index, byte) in value.utf8.enumerated() { bytes[offset + index] = byte }
            }
            func word(_ value: UInt16, at offset: Int) {
                bytes[offset] = UInt8(value & 255)
                bytes[offset + 1] = UInt8(value >> 8)
            }
            func dword(_ value: UInt32, at offset: Int) {
                word(UInt16(value & 65_535), at: offset)
                word(UInt16(value >> 16), at: offset + 2)
            }
            let payload = UInt32(samples.count * 2)
            text("RIFF", at: 0); dword(36 + payload, at: 4)
            text("WAVEfmt ", at: 8); dword(16, at: 16)
            word(1, at: 20); word(1, at: 22)
            dword(UInt32(playbackRate), at: 24); dword(UInt32(playbackRate * 2), at: 28)
            word(2, at: 32); word(16, at: 34)
            text("data", at: 36); dword(payload, at: 40)
            for index in samples.indices {
                if index % 16_384 == 0 { try Task.checkCancellation() }
                let sample = Int16(max(-32_768, min(32_767, Int((Double(samples[index]) * scale * 32_767).rounded()))))
                word(UInt16(bitPattern: sample), at: 44 + index * 2)
            }
        }
        return result
    }

    /// The converter calls this local provider synchronously. The lock also protects
    /// callback state if AVFoundation invokes it on a different execution thread.
    private final class Input: @unchecked Sendable {
        private let samples: [Float]
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var position = 0
        private var cancelled = false

        init(samples: [Float], format: AVAudioFormat) throws {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
                throw PicoFoxError.invalid("Audio preview input could not be allocated.")
            }
            self.samples = samples
            self.buffer = buffer
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func provide(requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            if Task.isCancelled {
                cancelled = true
                status.pointee = .endOfStream
                return nil
            }
            guard position < samples.count else {
                status.pointee = .endOfStream
                return nil
            }
            let count = min(Int(requested), Int(buffer.frameCapacity), samples.count - position)
            guard count > 0, let channel = buffer.floatChannelData?[0] else {
                status.pointee = .noDataNow
                return nil
            }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!.advanced(by: position), count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            position += count
            status.pointee = .haveData
            return buffer
        }
    }
}
