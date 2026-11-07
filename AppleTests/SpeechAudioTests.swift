// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class SpeechAudioTests: XCTestCase {
    @MainActor
    func testInvalidTextAndRatesFailBeforeSynthesis() async {
        let service = SpeechAudio()
        for text in ["", " \n\t", String(repeating: "x", count: 2001)] {
            do { _ = try await service.generate(text: text, voiceID: nil); XCTFail("Must reject invalid text") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        for rate in [-0.1, 1.1, Double.nan, Double.infinity] {
            do { _ = try await service.generate(text: "PicoFox", voiceID: nil, rate: rate); XCTFail("Must reject invalid rate") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testFloatStereoConvertsFiniteMonoSamples() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 2, interleaved: false, frames: 3)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 0.5; channels[1][0] = 0.1
        channels[0][1] = -1; channels[1][1] = 1
        channels[0][2] = 0.3; channels[1][2] = -0.1
        let audio = try SpeechAudio.monoAudio(from: buffer)
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertEqual(audio.samples.count, 3)
        XCTAssertEqual(audio.samples[0], 0.3, accuracy: 0.000_001)
        XCTAssertEqual(audio.samples[1], 0, accuracy: 0.000_001)
        XCTAssertEqual(audio.samples[2], 0.1, accuracy: 0.000_001)
    }

    func testInterleavedInt16AndMonoInt32ConvertCorrectly() throws {
        let stereo = try makeBuffer(format: .pcmFormatInt16, channels: 2, interleaved: true, frames: 3)
        let short = try XCTUnwrap(stereo.int16ChannelData)[0]
        for (i, value) in [Int16.min, Int16.max, 16384, 0, -16384, -16384].enumerated() { short[i] = value }
        let mixed = try SpeechAudio.monoAudio(from: stereo)
        XCTAssertEqual(mixed.samples[0], -1.0 / 65536, accuracy: 0.000_001)
        XCTAssertEqual(mixed.samples[1], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(mixed.samples[2], -0.5, accuracy: 0.000_001)

        let mono = try makeBuffer(format: .pcmFormatInt32, channels: 1, interleaved: false, frames: 3)
        let integers = try XCTUnwrap(mono.int32ChannelData)[0]
        integers[0] = .min; integers[1] = 0; integers[2] = .max
        let audio = try SpeechAudio.monoAudio(from: mono)
        XCTAssertEqual(audio.samples, [-1, 0, 1])
    }

    func testHotFloatPCMIsPreservedWithoutFlatteningPeaks() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 3)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        channel[0] = 1.5; channel[1] = -1.5; channel[2] = 0.75
        let audio = try SpeechAudio.monoAudio(from: buffer)
        XCTAssertEqual(audio.samples, [1.5, -1.5, 0.75])
        XCTAssertEqual(audio.samples[2] / audio.samples[0], 0.5)
    }

    func testHotSpeechSourceNormalizesWithHeadroomAndPreservesWaveform() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 4_800)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<4_800 {
            channel[frame] = Float(1.5 * sin(2 * Double.pi * 600 * Double(frame) / 24_000))
        }
        let source = try SpeechAudio.monoAudio(from: buffer)
        XCTAssertEqual(source.samples.map(abs).max() ?? 0, 1.5, accuracy: 0.000_001)
        let edited = try source.edited(start: 0, end: source.duration, gainDB: -6, normalize: true, fadeSeconds: 0.02)
        let expectedPeak = 0.95 * pow(10.0, -6.0 / 20)
        XCTAssertEqual(Double(edited.samples.map(abs).max() ?? 0), expectedPeak, accuracy: 0.000_001)
        XCTAssertEqual(edited.samples.first, 0)
        XCTAssertEqual(edited.samples.last, 0)
        let expectedScale = expectedPeak / 1.5
        // All samples outside the fades must retain the original sine shape, including the
        // overrange peaks. A clamp at import would produce a large residual and harmonics.
        let maximumResidual = (480..<4_320).reduce(0.0) {
            max($0, abs(Double(edited.samples[$1]) - Double(source.samples[$1]) * expectedScale))
        }
        XCTAssertLessThan(maximumResidual, 0.000_001)
    }

    func testRejectsNonfinitePCMAndSampleRateChanges() throws {
        let first = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 1)
        let samples = try XCTUnwrap(first.floatChannelData)[0]
        samples[0] = .nan
        XCTAssertThrowsError(try SpeechAudio.monoAudio(from: first))
        samples[0] = .infinity
        XCTAssertThrowsError(try SpeechAudio.monoAudio(from: first))
        samples[0] = 0.5
        let accumulator = SpeechBufferAccumulator()
        XCTAssertNil(accumulator.consume(first))
        let next = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 1, rate: 16_000)
        try XCTUnwrap(next.floatChannelData)[0][0] = 0.5
        let result = try XCTUnwrap(accumulator.consume(next))
        XCTAssertThrowsError(try result.get())
        XCTAssertNil(accumulator.finish())
    }

    func testStreamCompletionAndCancellationIgnoreLateBuffers() throws {
        let buffer = try makeBuffer(format: .pcmFormatFloat32, channels: 1, interleaved: false, frames: 2)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        samples[0] = 0.25; samples[1] = -0.25
        let accumulator = SpeechBufferAccumulator()
        XCTAssertNil(accumulator.consume(buffer))
        XCTAssertNil(accumulator.consume(buffer))
        buffer.frameLength = 0
        let audio = try XCTUnwrap(accumulator.consume(buffer)).get()
        XCTAssertEqual(audio.samples, [0.25, -0.25, 0.25, -0.25])
        XCTAssertNil(accumulator.finish())
        XCTAssertNil(accumulator.consume(buffer))

        let cancelled = SpeechBufferAccumulator()
        cancelled.cancel()
        XCTAssertNil(cancelled.consume(buffer))
        XCTAssertNil(cancelled.finish())
        XCTAssertThrowsError(try XCTUnwrap(SpeechBufferAccumulator().finish()).get())
    }

    func testRejectsAccumulatedAudioOverTenMinutes() throws {
        let buffer = try makeBuffer(format: .pcmFormatInt16, channels: 1, interleaved: false, frames: 1000, rate: 1000)
        try XCTUnwrap(buffer.int16ChannelData)[0].initialize(repeating: 0, count: 1000)
        let accumulator = SpeechBufferAccumulator()
        for _ in 0..<600 { XCTAssertNil(accumulator.consume(buffer)) }
        XCTAssertThrowsError(try XCTUnwrap(accumulator.consume(buffer)).get())
        XCTAssertNil(accumulator.finish())
    }

    @MainActor
    func testCancelledTaskDoesNotBeginSpeech() async {
        let service = SpeechAudio()
        let task = Task { try await service.generate(text: "PicoFox", voiceID: nil) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled generation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        service.cancel()
    }

    @MainActor
    func testInstalledSystemVoiceCreatesEditableAudio() async throws {
        guard ProcessInfo.processInfo.environment["PICOFOX_RUN_SPEECH_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt in to system-voice synthesis with PICOFOX_RUN_SPEECH_INTEGRATION=1.")
        }
        let service = SpeechAudio(timeout: .seconds(15))
        defer { service.cancel() }
        guard let voice = service.voices.first else { throw XCTSkip("No installed system voice is available.") }
        let audio = try await service.generate(text: "PicoFox test.", voiceID: voice.id)
        XCTAssertFalse(audio.samples.isEmpty)
        XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(audio.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.001)
        XCTAssertGreaterThan(audio.duration, 0.1)
        XCTAssertLessThan(audio.duration, 15)
        let exported = try audio.picoFoxWAV()
        XCTAssertEqual(try WaveAudio.decode(exported).sampleRate, 5000)
    }

    private func makeBuffer(format: AVAudioCommonFormat, channels: AVAudioChannelCount,
                            interleaved: Bool, frames: AVAudioFrameCount, rate: Double = 24_000) throws -> AVAudioPCMBuffer {
        let audioFormat = try XCTUnwrap(AVAudioFormat(commonFormat: format, sampleRate: rate, channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: max(1, frames)))
        buffer.frameLength = frames
        return buffer
    }
}
