// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation
import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class AudioPreviewTests: XCTestCase {
    func testLegacyRateUpsamplingRejectsImagesAndKeepsTone() throws {
        let source = try sine(rate: 5_000, frames: 5_000, frequencies: [(600, 0.5)])
        let output = try WaveAudio.decode(AudioPreview.render(source, radio: false))
        XCTAssertEqual(output.sampleRate, 48_000)
        XCTAssertEqual(output.samples.count, 48_000)
        XCTAssertEqual(amplitude(output, hz: 600), 0.5, accuracy: 0.01)
        XCTAssertLessThan(amplitude(output, hz: 4_400), 0.002)
        XCTAssertLessThan(amplitude(output, hz: 5_600), 0.002)
    }

    func testFullAndRadioPreviewKeepExactSelectionDurationAndDifferentBandwidths() throws {
        let source = try sine(rate: 44_100, frames: 22_073, frequencies: [(600, 0.3), (7_000, 0.3)])
        let full = try WaveAudio.decode(AudioPreview.render(source, radio: false))
        let radio = try WaveAudio.decode(AudioPreview.render(source, radio: true))
        let expected = Int((Double(source.samples.count) * 48_000 / 44_100).rounded())
        XCTAssertEqual(full.samples.count, expected)
        XCTAssertEqual(radio.samples.count, expected)
        XCTAssertEqual(amplitude(full, hz: 600), 0.3, accuracy: 0.01)
        XCTAssertEqual(amplitude(full, hz: 7_000), 0.3, accuracy: 0.01)
        XCTAssertEqual(amplitude(radio, hz: 600), 0.3, accuracy: 0.015)
        XCTAssertLessThan(amplitude(radio, hz: 7_000), 0.002)
        XCTAssertLessThan(amplitude(radio, hz: 2_000), 0.002, "Downsampling must reject the 7 kHz alias")
    }

    func testInputCallbacksAdvanceAcrossChunksInsteadOfRepeatingSamples() throws {
        let first = try sine(rate: 22_050, frames: 22_050, frequencies: [(600, 0.4)])
        let second = try sine(rate: 22_050, frames: 22_050, frequencies: [(1_200, 0.4)])
        let source = try WaveAudio(sampleRate: 22_050, samples: first.samples + second.samples)
        let output = try WaveAudio.decode(AudioPreview.render(source, radio: false))
        XCTAssertEqual(output.samples.count, 96_000)
        XCTAssertEqual(amplitude(output, hz: 600, start: 0.1, end: 0.9), 0.4, accuracy: 0.01)
        XCTAssertLessThan(amplitude(output, hz: 1_200, start: 0.1, end: 0.9), 0.002)
        XCTAssertEqual(amplitude(output, hz: 1_200, start: 1.1, end: 1.9), 0.4, accuracy: 0.01)
        XCTAssertLessThan(amplitude(output, hz: 600, start: 1.1, end: 1.9), 0.002)
    }

    func testSilenceAndNativeRateHeadroomArePreserved() throws {
        let silence = try WaveAudio(sampleRate: 8_000, samples: [Float](repeating: 0, count: 4_000))
        for radio in [false, true] {
            let output = try WaveAudio.decode(AudioPreview.render(silence, radio: radio))
            XCTAssertEqual(output.samples.count, 24_000)
            XCTAssertTrue(output.samples.allSatisfy { $0 == 0 })
        }
        var samples = [Float](repeating: 0.25, count: 4_800)
        samples[2_400] = 2
        let overloaded = try WaveAudio(sampleRate: 48_000, samples: samples)
        let data = try AudioPreview.render(overloaded, radio: false)
        XCTAssertEqual(data, overloaded.pcm16WAV(), "The equal-rate path must keep the existing uniform peak protection")
        let output = try WaveAudio.decode(data)
        XCTAssertEqual(output.samples[100], 0.125, accuracy: 0.00004)
        XCTAssertEqual(output.samples[2_400], 1, accuracy: 0.00004)
        XCTAssertTrue(output.samples.allSatisfy { abs($0) <= 1 })
    }

    func testNative48kFastPathMatchesCanonicalEncoderAndRejectsInvalidSamples() throws {
        let source = try sine(rate: 48_000, frames: 12_345, frequencies: [(900, 0.45)])
        XCTAssertEqual(try AudioPreview.render(source, radio: false), source.pcm16WAV())
        var invalid = source
        invalid.samples[0] = .nan
        XCTAssertThrowsError(try AudioPreview.render(invalid, radio: false))
    }

    func testCancelledRenderDoesNotEncodeOrConvert() async throws {
        let source = try sine(rate: 5_000, frames: 5_000, frequencies: [(600, 0.5)])
        let gate = AsyncStream<Void>.makeStream()
        let render = Task.detached {
            for await _ in gate.stream { break }
            return try AudioPreview.render(source, radio: false)
        }
        render.cancel()
        gate.continuation.finish()
        do {
            _ = try await render.value
            XCTFail("Cancelled preview rendering should throw CancellationError")
        } catch is CancellationError {
        }
    }

    func testFactoryPreviewBenchmarkWhenRequested() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PICOFOX_AUDIO_PREVIEW_BENCHMARK"] == "1",
                          "Set PICOFOX_AUDIO_PREVIEW_BENCHMARK=1 to compare the 28.8-second native and portable preview paths.")
        let source = try WaveAudio.decode(FactoryAudio.wavData())
        let nativeStart = ContinuousClock.now
        let native = try AudioPreview.render(source, radio: false)
        let nativeDuration = ContinuousClock.now - nativeStart
        let portableStart = ContinuousClock.now
        let portable = try source.previewWAV()
        let portableDuration = ContinuousClock.now - portableStart
        XCTAssertEqual(native.count, portable.count)
        let timing = XCTAttachment(string: "28.8 s / 5 kHz source: native \(nativeDuration), portable \(portableDuration)")
        timing.lifetime = .keepAlways
        add(timing)
    }

    private func sine(rate: Int, frames: Int, frequencies: [(Double, Double)]) throws -> WaveAudio {
        try WaveAudio(sampleRate: rate, samples: (0..<frames).map { index in
            Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1.0 * Double(index) / Double(rate)) * $1.1 })
        })
    }

    private func amplitude(_ audio: WaveAudio, hz: Double, start: Double? = nil, end: Double? = nil) -> Double {
        let lower = Int((start ?? audio.duration * 0.1) * Double(audio.sampleRate))
        let upper = Int((end ?? audio.duration * 0.9) * Double(audio.sampleRate))
        let count = upper - lower
        var sine = 0.0, cosine = 0.0, weight = 0.0
        for position in 0..<count {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(position) / Double(count - 1))
            let phase = 2 * .pi * hz * Double(lower + position) / Double(audio.sampleRate)
            sine += Double(audio.samples[lower + position]) * sin(phase) * window
            cosine += Double(audio.samples[lower + position]) * cos(phase) * window
            weight += window
        }
        return 2 * hypot(sine, cosine) / weight
    }
}
