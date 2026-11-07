// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation
import XCTest
import PicoFoxCore

final class DeviceAudioTests: XCTestCase {
    private func set32(_ offset: Int, _ value: UInt32, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }

    private func firmwareWAV(payloadBytes: Int = 288_000, declaredPayload: UInt32 = 300_000) throws -> Data {
        let source = try WaveAudio(sampleRate: 5000, samples: [Float](repeating: 0.25, count: max(1, payloadBytes / 2)))
        var data = try source.picoFoxWAV()
        if payloadBytes == 0 { data = data.prefix(44) }
        set32(4, declaredPayload + 36, in: &data)
        set32(40, declaredPayload, in: &data)
        return data
    }

    func testReadsFactoryAudioWithOversizedHeaderWithoutChangingInput() throws {
        let data = try firmwareWAV()
        let original = data
        XCTAssertEqual(data.count, 288_044)
        XCTAssertThrowsError(try WaveAudio.decode(data))
        let audio = try WaveAudio.decodePicoFox(data)
        XCTAssertEqual(audio.sampleRate, 5000)
        XCTAssertEqual(audio.samples.count, 144_000)
        XCTAssertEqual(audio.duration, 28.8, accuracy: 0.000_001)
        XCTAssertEqual(audio.samples[1000], 0.25, accuracy: 0.000_1)
        XCTAssertEqual(data, original)

        let canonical = try audio.picoFoxWAV()
        XCTAssertEqual(canonical.count, data.count)
        XCTAssertEqual(try WaveAudio.decode(canonical), audio)
        XCTAssertEqual(Array(canonical[4..<8]), [0x24, 0x65, 0x04, 0])
        XCTAssertEqual(Array(canonical[40..<44]), [0x00, 0x65, 0x04, 0])
    }

    func testVariableLengthFirmwareCallsignHeaderIsNotTreatedAsFactoryAudio() throws {
        let source = try WaveAudio(sampleRate: 5000, samples: [Float](repeating: 0.25, count: 12_904))
        let canonical = source.pcm16WAV()
        var staleHeader = canonical
        set32(4, 300_036, in: &staleHeader)
        set32(40, 300_000, in: &staleHeader)
        XCTAssertEqual(staleHeader.count, 25_852)
        XCTAssertThrowsError(try WaveAudio.decode(staleHeader))
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(staleHeader))
        XCTAssertEqual(try WaveAudio.decode(canonical).samples.count, 12_904)
        XCTAssertEqual(Array(canonical[4..<8]), [0xF4, 0x64, 0, 0])
        XCTAssertEqual(Array(canonical[40..<44]), [0xD0, 0x64, 0, 0])
    }

    func testValidWAVStillUsesStrictDecoder() throws {
        let data = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        XCTAssertEqual(try WaveAudio.decodePicoFox(data), try WaveAudio.decode(data))
    }

    func testDoesNotRepairOtherWAVFormatsOrChunkLayouts() throws {
        let original = try firmwareWAV()
        // Every field of the firmware's fixed canonical layout must match.
        let invalidFields: [(Int, UInt8)] = [
            (0, 0), (8, 0), (12, 0), (36, 0), (16, 18),
            (20, 6), (20, 3), (22, 2), (24, 0x44), (28, 0), (32, 4), (34, 24)
        ]
        for (offset, value) in invalidFields {
            var data = original
            data[offset] = value
            XCTAssertThrowsError(try WaveAudio.decodePicoFox(data), "Must reject header field at \(offset)")
        }
    }

    func testRejectsIncompleteFramesEmptyPayloadAndInconsistentLengths() throws {
        let original = try firmwareWAV()
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(original.dropLast()))
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(firmwareWAV(payloadBytes: 0, declaredPayload: 2000)))

        var inconsistent = original
        set32(4, 300_038, in: &inconsistent)
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(inconsistent))

        var oddDeclaration = original
        set32(4, 300_037, in: &oddDeclaration)
        set32(40, 300_001, in: &oddDeclaration)
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(oddDeclaration))

        var undersizedRIFF = original
        set32(4, 36, in: &undersizedRIFF)
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(undersizedRIFF))
    }

    func testDoesNotMaskTruncatedDeviceAudioOrOtherOversizedDeclarations() throws {
        let factory = try firmwareWAV()
        // The damaged physical files retained one 1,024-byte cluster. Whole PCM frames alone
        // must never make a truncated allocation chain look like successfully recovered audio.
        for length in [44, 46, 1024, 2000, 288_042] {
            XCTAssertThrowsError(try WaveAudio.decodePicoFox(factory.prefix(length)), "Must reject \(length)-byte truncation")
        }
        var differentDeclaration = factory
        set32(4, 300_038, in: &differentDeclaration)
        set32(40, 300_002, in: &differentDeclaration)
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(differentDeclaration))
    }

    func testRejectsCompatibilityRecoveryOverSizeLimit() throws {
        var oversized = try firmwareWAV(payloadBytes: 1000, declaredPayload: 12_000_002)
        oversized.append(Data(repeating: 0, count: 12_000_002 - oversized.count))
        XCTAssertGreaterThan(oversized.count, 12_000_000)
        XCTAssertThrowsError(try WaveAudio.decodePicoFox(oversized))
    }
}
