// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation
import XCTest
import PicoFoxCore

final class AudioQualityTests: XCTestCase {
    private func amplitude(_ audio: WaveAudio, at hz: Double) -> Double {
        let lo = audio.sampleRate / 10
        let hi = audio.samples.count - lo
        var sine = 0.0, cosine = 0.0
        for i in lo..<hi {
            let phase = 2 * Double.pi * hz * Double(i) / Double(audio.sampleRate)
            sine += Double(audio.samples[i]) * sin(phase)
            cosine += Double(audio.samples[i]) * cos(phase)
        }
        return 2 * hypot(sine, cosine) / Double(hi - lo)
    }

    func testGeneratedTonePreviewIsCleanAt48kWithSmoothEnds() throws {
        let tone = try WaveAudio.tone(hz: 600, seconds: 1)
        XCTAssertEqual(tone.sampleRate, 48000)
        let preview = try WaveAudio.decode(tone.previewWAV())
        XCTAssertEqual(preview.sampleRate, 48000)
        XCTAssertEqual(preview.samples.count, 48000)
        XCTAssertEqual(preview.samples.first, 0)
        XCTAssertEqual(preview.samples.last, 0)
        XCTAssertEqual(amplitude(preview, at: 600), 0.5, accuracy: 0.0001)
        for harmonic in [1200.0, 1800, 2400, 3000, 4400, 5600] {
            XCTAssertLessThan(amplitude(preview, at: harmonic), 0.0001)
        }
        let radio = try WaveAudio.decode(tone.picoFoxWAV())
        XCTAssertEqual(radio.sampleRate, 5000)
        XCTAssertEqual(radio.samples.count, 5000)
    }

    func testLegacy5kToneIsReconstructedWithoutAudibleImages() throws {
        let tone = try WaveAudio.tone(hz: 600, seconds: 1, sampleRate: 5000)
        let preview = try WaveAudio.decode(tone.previewWAV())
        XCTAssertEqual(preview.sampleRate, 48000)
        XCTAssertEqual(preview.duration, 1, accuracy: 0.00001)
        XCTAssertEqual(amplitude(preview, at: 600), 0.5, accuracy: 0.001)
        XCTAssertLessThan(amplitude(preview, at: 4400), 0.0005)
        XCTAssertLessThan(amplitude(preview, at: 5600), 0.0005)
    }

    func testPositiveGainProtectsPeaksWithoutFlatTopping() throws {
        let source = try WaveAudio.tone(hz: 600, seconds: 1)
        for normalize in [false, true] {
            let edited = try source.edited(start: 0, end: 1, gainDB: 24, normalize: normalize, fadeSeconds: 0)
            let result = try WaveAudio.decode(edited.previewWAV())
            XCTAssertEqual(amplitude(result, at: 600), 1, accuracy: 0.0001)
            XCTAssertLessThan(amplitude(result, at: 1800), 0.0001)
            XCTAssertLessThan(amplitude(result, at: 3000), 0.0001)
            XCTAssertLessThanOrEqual(result.samples.map { abs($0) }.max() ?? 0, 1)
        }
    }

    func testFullAndRadioPreviewsKeepDurationAndExposeRadioBandwidth() throws {
        var samples = [Float]()
        for i in 0..<44100 {
            let time = Double(i) / 44100.0
            let low = 0.25 * sin(2.0 * Double.pi * 600.0 * time)
            let high = 0.25 * sin(2.0 * Double.pi * 8000.0 * time)
            samples.append(Float(low + high))
        }
        let source = try WaveAudio(sampleRate: 44100, samples: samples)
        let full = try WaveAudio.decode(source.previewWAV())
        let radio = try WaveAudio.decode(source.previewWAV(radio: true))
        for audio in [full, radio] {
            XCTAssertEqual(audio.sampleRate, 48000)
            XCTAssertEqual(audio.duration, 1, accuracy: 0.00001)
            XCTAssertEqual(amplitude(audio, at: 600), 0.25, accuracy: 0.001)
        }
        XCTAssertEqual(amplitude(full, at: 8000), 0.25, accuracy: 0.001)
        XCTAssertLessThan(amplitude(radio, at: 8000), 0.001)
    }

    func testPCMEncoderUsesUniformHeadroomForFilterOvershoot() throws {
        let source = try WaveAudio(sampleRate: 48000, samples: [0.5, 1.25, -1.25, -0.5])
        let decoded = try WaveAudio.decode(source.pcm16WAV())
        XCTAssertEqual(decoded.samples[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(decoded.samples[1], 1, accuracy: 0.0001)
        XCTAssertEqual(decoded.samples[3], -0.4, accuracy: 0.0001)
    }
}
