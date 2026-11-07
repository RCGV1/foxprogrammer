// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation
import XCTest
import PicoFoxCore

final class FactoryAudioTests: XCTestCase {
    func testFactoryRecordingUsesCanonicalDeviceFormat() throws {
        let data = try FactoryAudio.wavData()
        XCTAssertEqual(data.count, 288_044)
        guard data.count == 288_044 else { return }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Array(data[4..<8]), [0x24, 0x65, 0x04, 0])
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(Array(data[16..<36]), [16, 0, 0, 0, 1, 0, 1, 0, 0x88, 0x13, 0, 0, 0x10, 0x27, 0, 0, 2, 0, 16, 0])
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(Array(data[40..<44]), [0, 0x65, 0x04, 0])

        let audio = try WaveAudio.decode(data)
        XCTAssertEqual(audio.sampleRate, 5000)
        XCTAssertEqual(audio.samples.count, 144_000)
        XCTAssertEqual(audio.duration, 28.8, accuracy: 0.000_001)
    }

    func testFactoryRecordingPreservesOriginalFirmwarePayload() throws {
        let data = try FactoryAudio.wavData()
        XCTAssertEqual(data.count, 288_044)
        guard data.count == 288_044 else { return }
        let firstLoop = data[44..<48_044]
        for loop in 1..<6 {
            let start = 44 + loop * 48_000
            XCTAssertEqual(data[start..<(start + 48_000)], firstLoop)
        }
        // Stable content fingerprint without a platform-specific cryptography dependency.
        let fingerprint = data.dropFirst(44).reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        XCTAssertEqual(fingerprint, 0xF6F1_7313_8385_5331)
    }
}
