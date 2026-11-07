// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class DeviceConnectionTests: XCTestCase {
    @MainActor
    func testUnreadableAudioStillOpensSettingsAndAllowsLocalEditing() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: false)
        let markerURL = audioURL.appendingPathComponent("original.txt")
        let marker = Data("Keep the unreadable original.".utf8)
        try marker.write(to: markerURL)
        let studio = StudioModel(defaults: defaults)

        await studio.connect(folder)

        XCTAssertEqual(studio.settings.callsign, "N0CALL")
        XCTAssertNotNil(studio.device)
        XCTAssertNotNil(studio.device?.audioReadError)
        XCTAssertNil(studio.audio)
        XCTAssertNil(studio.error)
        XCTAssertNotNil(defaults.data(forKey: "PicoFoxFolder"))

        studio.generateTone()
        studio.trimStart = 0.25
        studio.trimEnd = 0.75
        studio.gainDB = -6
        let exported = try WaveAudio.decode(await studio.renderedAudio())
        XCTAssertEqual(exported.sampleRate, 5_000)
        XCTAssertEqual(exported.duration, 0.5, accuracy: 0.0001)
        XCTAssertNil(studio.error)
        await studio.saveAudioToDevice()
        XCTAssertTrue(studio.error?.contains("cannot be read safely") == true)
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
        XCTAssertEqual(studio.audioName, "600 Hz test tone")
    }

    @MainActor
    func testAutomaticallyReopensPreviouslyAuthorizedFolder() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wave = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        try wave.write(to: folder.appendingPathComponent("audio.wav"))
        let authorized = try await DeviceFiles().open(folder)
        defaults.set(authorized.bookmark, forKey: "PicoFoxFolder")

        let studio = StudioModel(defaults: defaults)
        await studio.reconnectIfNeeded()

        XCTAssertEqual(studio.device?.settings, authorized.settings)
        XCTAssertEqual(studio.device?.audio, wave)
        XCTAssertEqual(studio.settings.callsign, "N0CALL")
        XCTAssertEqual(studio.audio?.duration ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(studio.playback.state, .stopped)
        XCTAssertFalse(studio.busy)
        XCTAssertNil(studio.error)
        XCTAssertTrue(studio.deviceIsAvailable)
        XCTAssertTrue(studio.canSaveToDevice)
    }

    @MainActor
    func testLocalSettingsDraftPreventsAutomaticReplacement() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        defaults.set(try await DeviceFiles().open(folder).bookmark, forKey: "PicoFoxFolder")
        let studio = StudioModel(defaults: defaults)
        studio.settings.callsign = "N1DRAFT"
        studio.settings.frequencyMHz = 145.5
        let draft = studio.settings

        await studio.reconnectIfNeeded()

        XCTAssertEqual(studio.settings, draft)
        XCTAssertNil(studio.device)
        XCTAssertNil(studio.audio)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testLoadedAudioAndEditsPreventAutomaticReplacement() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        defaults.set(try await DeviceFiles().open(folder).bookmark, forKey: "PicoFoxFolder")
        let studio = StudioModel(defaults: defaults)
        let local = try WaveAudio.tone(hz: 900, seconds: 1)
        studio.load(local, name: "Local.wav")
        studio.trimStart = 0.2
        studio.trimEnd = 0.8
        studio.gainDB = -6

        await studio.reconnectIfNeeded()

        XCTAssertEqual(studio.audio, local)
        XCTAssertEqual(studio.audioName, "Local.wav")
        XCTAssertEqual(studio.trimStart, 0.2)
        XCTAssertEqual(studio.trimEnd, 0.8)
        XCTAssertEqual(studio.gainDB, -6)
        XCTAssertNil(studio.device)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testExplicitCloseSuppressesAutomaticReconnectForTheSession() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        await studio.connect(folder)
        XCTAssertNotNil(defaults.data(forKey: "PicoFoxFolder"))
        studio.disconnect()
        studio.settings = PicoFoxSettings()

        await studio.reconnectIfNeeded()
        await studio.refreshConnection()

        XCTAssertNil(studio.device)
        XCTAssertEqual(studio.settings, PicoFoxSettings())
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)

        // An explicit Open remains available after Close.
        await studio.reconnect()
        XCTAssertNotNil(studio.device)
        XCTAssertTrue(studio.deviceIsAvailable)
        XCTAssertTrue(studio.canSaveToDevice)
        XCTAssertEqual(studio.settings.callsign, "N0CALL")
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testUnavailableFolderDoesNotReplaceStateOrShowAnAlert() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        defaults.set(try await DeviceFiles().open(folder).bookmark, forKey: "PicoFoxFolder")
        try FileManager.default.removeItem(at: folder)
        let studio = StudioModel(defaults: defaults)
        let original = studio.settings

        await studio.reconnectIfNeeded()
        await studio.reconnectIfNeeded()

        XCTAssertEqual(studio.settings, original)
        XCTAssertNil(studio.audio)
        XCTAssertNil(studio.device)
        XCTAssertNil(studio.error)
        XCTAssertFalse(studio.busy)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
    }

    @MainActor
    func testMissingBookmarkAndBusyWorkAreUntouched() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = StudioModel(defaults: defaults)
        await studio.reconnectIfNeeded()
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        defaults.set(try await DeviceFiles().open(folder).bookmark, forKey: "PicoFoxFolder")
        studio.busy = true

        await studio.reconnectIfNeeded()

        XCTAssertTrue(studio.busy)
        XCTAssertNil(studio.device)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)
    }

    @MainActor
    func testAvailabilityRefreshPreservesEditsBlocksOfflineSavesAndKeepsConflictChecks() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let settingsURL = folder.appendingPathComponent("settings.txt")
        let heldSettingsURL = folder.appendingPathComponent("held-settings.txt")
        let audioURL = folder.appendingPathComponent("audio.wav")
        let originalAudio = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        try originalAudio.write(to: audioURL)
        let studio = StudioModel(defaults: defaults)
        await studio.connect(folder)
        let selected = try XCTUnwrap(studio.device)
        let local = try WaveAudio.tone(hz: 900, seconds: 1)
        studio.load(local, name: "Local.wav")
        studio.settings.callsign = "N1DRAFT"
        studio.settings.frequencyMHz = 145.5
        studio.trimStart = 0.2
        studio.trimEnd = 0.8
        studio.gainDB = -6
        studio.normalize = true
        studio.fadeSeconds = 0.03
        let draft = studio.settings
        try FileManager.default.moveItem(at: settingsURL, to: heldSettingsURL)

        await studio.refreshConnection()

        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertEqual(studio.device?.bookmark, selected.bookmark)
        XCTAssertEqual(studio.device?.settings, selected.settings)
        XCTAssertEqual(studio.device?.audio, originalAudio)
        assertLocalSession(studio, settings: draft, source: local)
        XCTAssertNil(studio.error)

        await studio.saveSettingsToDevice()
        XCTAssertTrue(studio.error?.contains("Reconnect PicoFox") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertEqual(try Data(contentsOf: heldSettingsURL), selected.settings)
        studio.error = nil
        await studio.saveAudioToDevice()
        XCTAssertTrue(studio.error?.contains("Reconnect PicoFox") == true)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalAudio)
        assertLocalSession(studio, settings: draft, source: local)

        // The same authorized folder returns with changes made by another writer.
        let outsideSettings = Data("CALLSIGN=N2OTHER\nFREQ_MHZ=146.565\n".utf8)
        let outsideAudio = try WaveAudio.tone(hz: 300, seconds: 0.2).picoFoxWAV()
        try outsideSettings.write(to: heldSettingsURL)
        try outsideAudio.write(to: audioURL)
        try FileManager.default.moveItem(at: heldSettingsURL, to: settingsURL)
        studio.error = nil

        await studio.refreshConnection()

        XCTAssertTrue(studio.deviceIsAvailable)
        XCTAssertTrue(studio.canSaveToDevice)
        XCTAssertEqual(studio.device?.settings, selected.settings)
        XCTAssertEqual(studio.device?.audio, originalAudio)
        assertLocalSession(studio, settings: draft, source: local)
        XCTAssertNil(studio.error)

        await studio.saveSettingsToDevice()
        XCTAssertTrue(studio.error?.contains("changed outside") == true)
        XCTAssertEqual(try Data(contentsOf: settingsURL), outsideSettings)
        studio.error = nil
        await studio.saveAudioToDevice()
        XCTAssertTrue(studio.error?.contains("changed outside") == true)
        XCTAssertEqual(try Data(contentsOf: audioURL), outsideAudio)
        XCTAssertEqual(studio.device?.bookmark, selected.bookmark)
        XCTAssertEqual(studio.device?.settings, selected.settings)
        XCTAssertEqual(studio.device?.audio, originalAudio)
        assertLocalSession(studio, settings: draft, source: local)
        XCTAssertFalse(studio.busy)
    }

    @MainActor
    func testConnectionMonitorCancelsWithoutWaitingForItsPollingInterval() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        await studio.connect(folder)
        XCTAssertTrue(studio.deviceIsAvailable)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("settings.txt"),
                                         to: folder.appendingPathComponent("held-settings.txt"))
        var finished = false
        let monitor = Task { await studio.monitorConnection(); finished = true }
        defer { monitor.cancel() }
        try await waitUntil("The monitor should complete its first availability check") { !studio.deviceIsAvailable }

        let cancelledAt = ContinuousClock.now
        monitor.cancel()
        try await waitUntil("A cancelled monitor should finish promptly", timeout: .seconds(1)) { finished }
        await monitor.value

        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1))
        XCTAssertNotNil(studio.device)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertNil(studio.error)
    }

    @MainActor
    private func assertLocalSession(_ studio: StudioModel, settings: PicoFoxSettings, source: WaveAudio,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(studio.settings, settings, file: file, line: line)
        XCTAssertEqual(studio.audio, source, file: file, line: line)
        XCTAssertEqual(studio.audioName, "Local.wav", file: file, line: line)
        XCTAssertEqual(studio.trimStart, 0.2, file: file, line: line)
        XCTAssertEqual(studio.trimEnd, 0.8, file: file, line: line)
        XCTAssertEqual(studio.gainDB, -6, file: file, line: line)
        XCTAssertTrue(studio.normalize, file: file, line: line)
        XCTAssertEqual(studio.fadeSeconds, 0.03, file: file, line: line)
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: Duration = .seconds(5),
                           file: StaticString = #filePath, line: UInt = #line,
                           condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw WaitFailure.timedOut
            }
            await Task.yield()
        }
    }

    private enum WaitFailure: Error { case timedOut }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "PicoFox.DeviceConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func deviceFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("CALLSIGN=N0CALL\nFREQ_MHZ=146.565\n".utf8)
            .write(to: folder.appendingPathComponent("settings.txt"))
        return folder
    }
}
