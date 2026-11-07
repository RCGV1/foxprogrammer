// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class SpeechLevelTests: XCTestCase {
    @MainActor
    func testSpeechDefaultsPreserveHotSourceAndLeaveSixDecibelsOfHeadroom() async throws {
        var source = try WaveAudio.tone(hz: 600, seconds: 1)
        source.samples = source.samples.map { $0 * 4 }
        let studio = StudioModel()
        studio.load(source, name: "Speech", style: .speech)
        XCTAssertEqual(studio.audio, source, "Speech capture must not bake in clipping or edit gain")
        XCTAssertEqual(studio.gainDB, -6)
        XCTAssertTrue(studio.normalize)
        let edited = try source.edited(start: studio.trimStart, end: studio.trimEnd, gainDB: studio.gainDB,
                                       normalize: studio.normalize, fadeSeconds: studio.fadeSeconds)
        let preview = try WaveAudio.decode(AudioPreview.render(edited, radio: false))
        let peak = preview.samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertEqual(peak, Float(0.95 * pow(10, -6.0 / 20)), accuracy: 0.0001)
        let export = try WaveAudio.decode(await studio.renderedAudio())
        XCTAssertLessThan(export.samples.map(abs).max() ?? 1, 0.5)
        XCTAssertGreaterThan(export.samples.map(abs).max() ?? 0, 0.45)

        studio.gainDB = 12; studio.normalize = false; studio.trimStart = 0.2
        studio.resetEdits()
        XCTAssertEqual(studio.gainDB, -6)
        XCTAssertTrue(studio.normalize)
        XCTAssertEqual(studio.trimStart, 0)
        XCTAssertEqual(studio.audio, source)
    }

    @MainActor
    func testStandardAudioKeepsItsExistingDefaultsAfterSpeech() throws {
        let source = try WaveAudio.tone(seconds: 0.1)
        let studio = StudioModel()
        studio.load(source, name: "Speech", style: .speech)
        studio.load(source, name: "Tone")
        XCTAssertEqual(studio.gainDB, 0)
        XCTAssertFalse(studio.normalize)
    }
}
