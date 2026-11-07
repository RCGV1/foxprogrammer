// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class StudioPlaybackTests: XCTestCase {
    @MainActor
    func testStopDuringRenderCannotStartLatePlayback() async throws {
        let studio = StudioModel()
        studio.load(try source(seconds: 20), name: "Long source.wav")
        studio.previewMode = .fullQuality
        let request = Task { await studio.preview() }
        defer { request.cancel(); studio.stop() }

        try await waitUntil("Preview should begin rendering") { studio.busy }
        XCTAssertEqual(studio.playback.state, .stopped)
        studio.stop()
        try await waitUntil("Cancelled preview should release the busy state") { !studio.busy }
        await request.value

        XCTAssertNil(studio.error)
        XCTAssertEqual(studio.playback.state, .stopped)
        XCTAssertEqual(studio.playback.currentTime, 0)
        XCTAssertEqual(studio.playback.duration, 0)
    }

    @MainActor
    func testReplacingSourceCancelsPendingPicoFoxRender() async throws {
        let studio = StudioModel()
        studio.load(try source(seconds: 20), name: "Old source.wav")
        studio.previewMode = .picoFox
        let request = Task { await studio.preview() }
        defer { request.cancel(); studio.stop() }

        try await waitUntil("PicoFox preview should begin rendering") { studio.busy }
        let replacement = try source(seconds: 0.5)
        studio.load(replacement, name: "Replacement.wav")
        try await waitUntil("Replacing the source should cancel its pending render") { !studio.busy }
        await request.value

        XCTAssertNil(studio.error)
        XCTAssertEqual(studio.audioName, "Replacement.wav")
        XCTAssertEqual(studio.audio, replacement)
        XCTAssertEqual(studio.playback.state, .stopped)
        XCTAssertEqual(studio.playback.duration, 0)

        // A cancelled request must not leave a stale player or block the replacement.
        studio.previewMode = .fullQuality
        try await startPreview(studio)
        XCTAssertEqual(studio.playback.duration, 0.5, accuracy: 0.001)
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testBothPreviewModesKeepTrimDurationAndExportRemainsDeviceCompatible() async throws {
        let studio = StudioModel()
        defer { studio.stop() }
        studio.load(try source(seconds: 1), name: "48 kHz source.wav")
        studio.trimStart = 0.1
        studio.trimEnd = 0.7
        XCTAssertEqual(studio.previewMode, .fullQuality)

        for mode in [PreviewMode.fullQuality, .picoFox] {
            studio.stop()
            studio.previewMode = mode
            try await startPreview(studio)
            XCTAssertEqual(studio.playback.duration, 0.6, accuracy: 0.001, "\(mode) preview duration")
            XCTAssertEqual(studio.audio?.sampleRate, 48_000)
            XCTAssertNil(studio.error)
        }

        studio.stop()
        let exported = try WaveAudio.decode(await studio.renderedAudio())
        XCTAssertEqual(exported.sampleRate, 5_000)
        XCTAssertEqual(exported.samples.count, 3_000)
        XCTAssertEqual(exported.duration, 0.6, accuracy: 0.0001)
        XCTAssertNil(studio.error)
    }

    @MainActor
    private func startPreview(_ studio: StudioModel) async throws {
        let request = Task { await studio.preview() }
        defer { request.cancel() }
        try await waitUntil("Preview should start or report an error") {
            !studio.busy && (studio.isPlaying || studio.error != nil)
        }
        await request.value
        XCTAssertNil(studio.error)
        XCTAssertEqual(studio.playback.state, .playing)
    }

    @MainActor
    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw WaitFailure.timedOut
            }
            await Task.yield()
        }
    }

    private func source(seconds: Double) throws -> WaveAudio {
        // Native-rate silent PCM tests the renderer/player without microphone or test noise.
        try WaveAudio(sampleRate: 48_000, samples: [Float](repeating: 0, count: Int(seconds * 48_000)))
    }

    private enum WaitFailure: Error { case timedOut }
}
