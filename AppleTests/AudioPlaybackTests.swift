// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class AudioPlaybackTests: XCTestCase {
    @MainActor
    func testNativeRatePlaybackPauseResumeSeekAndStop() async throws {
        let playback = AudioPlayback()
        defer { playback.stop() }
        try playback.play(data: try nativeWAV(seconds: 2))
        XCTAssertEqual(playback.state, .playing)
        XCTAssertEqual(playback.duration, 2, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertGreaterThan(playback.currentTime, 0.05)

        playback.pause()
        XCTAssertEqual(playback.state, .paused)
        try await Task.sleep(for: .milliseconds(40))
        let pausedTime = playback.currentTime
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(playback.currentTime, pausedTime, accuracy: 0.005)

        playback.seek(to: -10)
        XCTAssertEqual(playback.currentTime, 0)
        playback.seek(to: 0.6)
        XCTAssertEqual(playback.currentTime, 0.6, accuracy: 0.001)
        playback.seek(to: .nan)
        XCTAssertEqual(playback.currentTime, 0.6, accuracy: 0.001)
        try playback.resume()
        XCTAssertTrue(playback.isPlaying)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(playback.currentTime, 0.65)

        playback.pause()
        try await Task.sleep(for: .milliseconds(20))
        playback.seek(to: 20)
        XCTAssertEqual(playback.currentTime, 2)
        try playback.resume()
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.03)

        playback.stop()
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
        XCTAssertThrowsError(try playback.resume())
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertEqual(playback.currentTime, 0)
    }

    @MainActor
    func testActualCompletionUpdatesStateAndProgress() async throws {
        let playback = AudioPlayback()
        defer { playback.stop() }
        var playbackError: String?
        playback.onError = { playbackError = $0 }
        try playback.play(data: try nativeWAV(seconds: 0.12))
        let deadline = ContinuousClock.now + .seconds(3)
        while playback.state != .stopped && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(playbackError)
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertEqual(playback.duration, 0.12, accuracy: 0.001)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
    }

    @MainActor
    func testReplacementIsNotStoppedByAnOldCompletionOrFade() async throws {
        let playback = AudioPlayback()
        defer { playback.stop() }
        try playback.play(data: try nativeWAV(seconds: 0.12))
        try await Task.sleep(for: .milliseconds(40))
        try playback.play(data: try nativeWAV(seconds: 2))
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(playback.state, .playing)
        XCTAssertEqual(playback.duration, 2, accuracy: 0.001)
        XCTAssertGreaterThan(playback.currentTime, 0.1)
    }

    @MainActor
    func testResumeCancelsPendingPause() async throws {
        let playback = AudioPlayback()
        defer { playback.stop() }
        try playback.play(data: try nativeWAV(seconds: 2))
        playback.pause()
        try playback.resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(playback.state, .playing)
        XCTAssertGreaterThan(playback.currentTime, 0.03)
    }

    @MainActor
    func testInvalidReplacementLeavesPlaybackStopped() throws {
        let playback = AudioPlayback()
        defer { playback.stop() }
        try playback.play(data: try nativeWAV(seconds: 2))
        XCTAssertThrowsError(try playback.play(data: Data("not an audio file".utf8)))
        XCTAssertEqual(playback.state, .stopped)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
    }

    private func nativeWAV(seconds: Double) throws -> Data {
        // Silent native-rate PCM exercises the actual player without microphone or test noise.
        try WaveAudio(sampleRate: 48_000, samples: [Float](repeating: 0, count: Int(seconds * 48_000))).pcm16WAV()
    }
}
