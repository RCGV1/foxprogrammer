// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore

final class CoreTests: XCTestCase {
    func testPowerSliderMappingAndDecibelCalculation() {
        XCTAssertEqual(PowerLevel.milliwatts(attenuation: 0), 65, accuracy: 0.000001)
        XCTAssertEqual(PowerLevel.milliwatts(attenuation: 40), 6.5, accuracy: 0.000001)
        XCTAssertEqual(PowerLevel.milliwatts(attenuation: 80), 0.65, accuracy: 0.000001)
        XCTAssertEqual(PowerLevel.attenuation(sliderStep: 127), 0)
        XCTAssertEqual(PowerLevel.attenuation(sliderStep: 0), 127)
        XCTAssertEqual(PowerLevel.attenuation(sliderStep: .nan), 127)
        for step in 0...127 {
            XCTAssertEqual(PowerLevel.attenuation(sliderStep: Double(127-step)), step)
        }
    }

    func testSettingsRoundTripPreservesExtensionsAndCollapsesDuplicateKeys() throws {
        var doc = try SettingsDocument(text: "# field profile\r\nCALLSIGN=OLD\r\nFREQ_MHZ=145.5\r\nCALLSIGN=NEW\r\nFUTURE_FEATURE=yes\r\n")
        doc.settings.callsign = "N0CALL"
        let data = try doc.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("# field profile"))
        XCTAssertTrue(text.contains("FUTURE_FEATURE=yes"))
        XCTAssertEqual(text.components(separatedBy: "CALLSIGN=").count, 2)
        XCTAssertEqual(try SettingsDocument(text: text).settings, doc.settings)
        XCTAssertTrue(text.contains("FREQ_MHZ=145.500000\n"))
    }
    func testCallsignBoundaries() {
        var settings = PicoFoxSettings()
        settings.callsign = "ABCDEFGHIJK"
        XCTAssertTrue(settings.issues.isEmpty)
        settings.callsign += "L"
        XCTAssertFalse(settings.issues.isEmpty)
    }
    func testFirmwareFrequencyRangesIncludeBothBoundariesInEveryZone() throws {
        for (zone, range) in [(1, 144.020...145.980), (2, 144.020...147.980), (3, 144.020...147.980)] {
            var document = try SettingsDocument()
            document.settings.callsign = "N0CALL"
            document.settings.ituZone = zone
            XCTAssertEqual(document.settings.frequencyRangeMHz, range)
            for frequency in [range.lowerBound, range.upperBound] {
                document.settings.frequencyMHz = frequency
                XCTAssertNil(document.settings.frequencyIssue)
                XCTAssertTrue(document.settings.issues.isEmpty)
                XCTAssertNoThrow(try document.encoded())
            }
        }
    }
    func testFirmwareFrequencyRejectsOutsideBoundsAndNonfiniteValuesInEveryZone() throws {
        for zone in 1...3 {
            var document = try SettingsDocument()
            document.settings.callsign = "N0CALL"
            document.settings.ituZone = zone
            let range = document.settings.frequencyRangeMHz
            let expected = zone == 1 ? "Frequency must be 144.020–145.980 MHz." : "Frequency must be 144.020–147.980 MHz."
            for frequency in [range.lowerBound.nextDown, range.upperBound.nextUp, .nan, .infinity, -.infinity] {
                document.settings.frequencyMHz = frequency
                XCTAssertEqual(document.settings.frequencyIssue, expected)
                XCTAssertTrue(document.settings.issues.contains(expected))
                XCTAssertThrowsError(try document.encoded())
            }
        }
    }
    func testChangingITUZoneImmediatelyRevalidatesFrequency() {
        var settings = PicoFoxSettings()
        settings.callsign = "N0CALL"
        settings.frequencyMHz = 146.565
        settings.ituZone = 2
        XCTAssertNil(settings.frequencyIssue)
        settings.ituZone = 1
        XCTAssertEqual(settings.frequencyIssue, "Frequency must be 144.020–145.980 MHz.")
        XCTAssertTrue(settings.issues.contains(settings.frequencyIssue!))
        settings.ituZone = 3
        XCTAssertNil(settings.frequencyIssue)
        XCTAssertTrue(settings.issues.isEmpty)
    }
    func testEmptyCallsignDoesNotHideFrequencyIssue() {
        var settings = PicoFoxSettings()
        settings.ituZone = 1
        settings.frequencyMHz = 146.565
        XCTAssertTrue(settings.callsign.isEmpty)
        XCTAssertEqual(settings.frequencyIssue, "Frequency must be 144.020–145.980 MHz.")
        XCTAssertTrue(settings.issues.contains("Use 1–11 uppercase letters or digits for the callsign."))
        XCTAssertTrue(settings.issues.contains("Frequency must be 144.020–145.980 MHz."))
    }
    func testMalformedSettingsAreNotSilentlyReset() {
        XCTAssertThrowsError(try SettingsDocument(text: "MORSE_WPM=fast"))
        XCTAssertThrowsError(try SettingsDocument(text: "FREQ_MHZ=nan"))
        var doc = try! SettingsDocument()
        doc.settings.callsign = "A\nDUTY_CYCLE=100"
        XCTAssertThrowsError(try doc.encoded())
    }
    func testSpacingAndNumericValidation() {
        var settings = PicoFoxSettings(); settings.callsign = "N0CALL"
        settings.farnsworthWPM = 10
        XCTAssertFalse(settings.issues.isEmpty)
        settings.farnsworthWPM = 15
        settings.dutyCycle = -1
        settings.morseWPM = Int.max
        XCTAssertFalse(settings.issues.isEmpty)
    }
    func testCanonicalWAVHasExactHeaderAndRoundTrips() throws {
        let tone = try WaveAudio.tone(hz: 600, seconds: 1, sampleRate: 5000)
        let data = try tone.picoFoxWAV()
        XCTAssertEqual(data.count, 10044)
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(Array(data[24..<28]), [0x88, 0x13, 0, 0])
        let decoded = try WaveAudio.decode(data)
        XCTAssertEqual(decoded.sampleRate, 5000)
        XCTAssertEqual(decoded.samples.count, 5000)
        XCTAssertEqual(decoded.samples[10], tone.samples[10], accuracy: 0.0001)
    }
    func testTrimNormalizeGainAndFade() throws {
        let audio = try WaveAudio(sampleRate: 5000, samples: [Float](repeating: 0.5, count: 10000))
        let edit = try audio.edited(start: 0.5, end: 1.5, gainDB: 0, normalize: true, fadeSeconds: 0.01)
        XCTAssertEqual(edit.samples.count, 5000)
        XCTAssertEqual(edit.samples.first, 0)
        XCTAssertEqual(edit.samples.last, 0)
        XCTAssertEqual(edit.samples[100], 0.95, accuracy: 0.00001)
        XCTAssertThrowsError(try audio.edited(start: 1, end: 0, gainDB: 0, normalize: false, fadeSeconds: 0))
        XCTAssertThrowsError(try audio.edited(start: .nan, end: 1, gainDB: 0, normalize: false, fadeSeconds: 0))
        let clipped = try audio.edited(start: 0, end: 1, gainDB: 24, normalize: false, fadeSeconds: 0)
        XCTAssertEqual(clipped.samples[100], 1)
    }
    func testResamplerRejectsAboveNyquistAndPreservesVoiceTone() throws {
        func sine(_ hz: Double) throws -> WaveAudio {
            try WaveAudio(sampleRate: 48000, samples: (0..<48000).map { Float(sin(2 * Double.pi * hz * Double($0) / 48000) * 0.5) })
        }
        func rms(_ a: WaveAudio) -> Double {
            let middle = a.samples[100..<(a.samples.count - 100)]
            return sqrt(middle.reduce(0) { $0 + Double($1 * $1) } / Double(middle.count))
        }
        let pass = try sine(600).resampled()
        let reject = try sine(8000).resampled()
        XCTAssertEqual(pass.samples.count, 5000)
        XCTAssertEqual(rms(pass), 0.35355, accuracy: 0.01)
        XCTAssertLessThan(rms(reject), 0.005)
    }
    func testWAVChunksAndStereoMix() throws {
        var bytes = Array(try WaveAudio.tone(seconds: 0.1).picoFoxWAV())
        // Two identical channels at half the sample count, unchanged data bytes.
        bytes[22] = 2; bytes[28] = 0x20; bytes[29] = 0x4E; bytes[32] = 4
        // An odd-sized metadata chunk before fmt, including padding.
        bytes.insert(contentsOf: [0x4A,0x55,0x4E,0x4B,1,0,0,0,0x7F,0], at: 12)
        let riffSize = bytes.count - 8
        for i in 0..<4 { bytes[4+i] = UInt8((riffSize >> (i*8)) & 255) }
        let decoded = try WaveAudio.decode(Data(bytes))
        XCTAssertEqual(decoded.samples.count, 250)
        let exported = try decoded.picoFoxWAV()
        XCTAssertEqual(String(decoding: exported[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(exported.count, 544)
    }
    func testRejectsCorruptAndNonfiniteWAV() throws {
        let good = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        for count in [0, 12, 43, good.count - 1] { XCTAssertThrowsError(try WaveAudio.decode(good.prefix(count))) }
        var bad = Array(good); bad[40] = 255; bad[41] = 255
        XCTAssertThrowsError(try WaveAudio.decode(Data(bad)))
        XCTAssertThrowsError(try WaveAudio(sampleRate: 5000, samples: [.nan]))
        XCTAssertThrowsError(try WaveAudio(sampleRate: 0, samples: [0]))
        XCTAssertThrowsError(try WaveAudio.tone(seconds: .infinity))
    }
}
