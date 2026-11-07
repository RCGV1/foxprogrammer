// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class AudioImportTests: XCTestCase {
    func testNativeAIFFImportDownmixesAndCanTrimForDeviceExport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 32_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = 0.5; buffer.floatChannelData![1][i] = 0.25 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 32_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let source = try await DeviceFiles().readImportedAudio(url)
        XCTAssertEqual(source.sampleRate, 32_000)
        XCTAssertEqual(source.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(source.samples[100], 0.375, accuracy: 0.0001)
        let trimmed = try source.edited(start: 0.2, end: 0.7, gainDB: 0, normalize: false, fadeSeconds: 0)
        let exported = try WaveAudio.decode(trimmed.picoFoxWAV())
        XCTAssertEqual(exported.sampleRate, 5_000)
        XCTAssertEqual(exported.duration, 0.5, accuracy: 0.0001)
    }

    func testNativeDecoderImportsAACM4A() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        for i in 0..<4_410 { buffer.floatChannelData![0][i] = Float(0.25 * sin(2 * Double.pi * 600 * Double(i) / 44_100)) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let source = try AudioImport.decode(url)
        XCTAssertEqual(source.sampleRate, 44_100)
        XCTAssertEqual(source.duration, 0.1, accuracy: 0.025)
        XCTAssertGreaterThan(source.samples.map(abs).max() ?? 0, 0.1)
    }

    @MainActor
    func testStoppingToneGenerationKeepsPreviousSource() async throws {
        let studio = StudioModel()
        let previous = try WaveAudio.tone(seconds: 0.1)
        studio.load(previous, name: "Original.wav")
        let generation = Task { await studio.generateTone(hz: 900, seconds: 60) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !studio.busy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(studio.busy)
        studio.stop()
        let completed = await generation.value
        XCTAssertFalse(completed)
        XCTAssertEqual(studio.audio, previous)
        XCTAssertEqual(studio.audioName, "Original.wav")
        XCTAssertFalse(studio.busy)
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testCustomToneUsesRequestedFrequencyDurationAndExistingTrimControls() async throws {
        let studio = StudioModel()
        let generated = await studio.generateTone(hz: 925, seconds: 1.5)
        XCTAssertTrue(generated)
        XCTAssertNil(studio.error)
        let audio = try XCTUnwrap(studio.audio)
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.duration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(studio.trimEnd, 1.5)
        XCTAssertTrue(studio.audioName.contains("925"))
        studio.trimStart = 0.25
        studio.trimEnd = 0.75
        let output = try WaveAudio.decode(await studio.renderedAudio())
        XCTAssertEqual(output.duration, 0.5, accuracy: 0.0001)
        let previous = studio.audio
        let invalid = await studio.generateTone(hz: 0, seconds: 1)
        XCTAssertFalse(invalid)
        XCTAssertEqual(studio.audio, previous)
        XCTAssertNotNil(studio.error)
    }
}
