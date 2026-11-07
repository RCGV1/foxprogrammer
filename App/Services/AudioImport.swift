// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import Foundation
import PicoFoxCore

/// Decode Apple-supported audio files into the same editable mono source as WAV imports.
enum AudioImport {
    static func decode(_ url: URL) throws -> WaveAudio {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64_000_000 else { throw PicoFoxError.invalid("Choose an audio file smaller than 64 MB.") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, (1000...192000).contains(format.sampleRate) else {
            throw PicoFoxError.invalid("Audio must use a sample rate between 1 and 192 kHz.")
        }
        let rate = Int(format.sampleRate.rounded())
        let channels = Int(format.channelCount)
        let limit = min(12_000_000, rate * 600)
        guard (1...8).contains(channels),
              file.length > 0, file.length <= limit,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw PicoFoxError.invalid("Audio must use 1–8 channels, 1–192 kHz, and fit within ten minutes and 12 million samples.")
        }
        var samples = [Float]()
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard samples.count + count <= limit, let data = buffer.floatChannelData else {
                throw PicoFoxError.invalid("Decoded audio exceeds the supported size.")
            }
            for frame in 0..<count {
                var mono: Float = 0
                for channel in 0..<channels { mono += data[channel][frame] / Float(channels) }
                samples.append(mono)
            }
        }
        return try WaveAudio(sampleRate: rate, samples: samples)
    }
}
