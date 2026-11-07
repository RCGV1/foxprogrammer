// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class FactoryRestoreTests: XCTestCase {
    @MainActor
    func testOfflineRestoreAndResetExportExactFactoryBytesWithoutChangingSettings() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        studio.settings.callsign = "N1DRAFT"
        studio.settings.frequencyMHz = 145.5
        let settings = studio.settings
        let factory = try FactoryAudio.wavData()

        await studio.restoreDefaultAudio()

        XCTAssertNil(studio.error)
        XCTAssertNil(studio.device)
        XCTAssertNil(studio.lastRestoreBackup)
        XCTAssertNil(studio.lastDeviceAudioBackup)
        XCTAssertEqual(studio.settings, settings)
        XCTAssertEqual(studio.audio, try WaveAudio.decode(factory))
        XCTAssertEqual(studio.fadeSeconds, 0)
        let rendered = try await studio.renderedAudio()
        XCTAssertEqual(rendered, factory)
        let export = await studio.prepareAudioExport()
        XCTAssertEqual(export?.data, factory)

        studio.trimStart = 1
        studio.gainDB = -6
        studio.fadeSeconds = 0.1
        studio.resetEdits()
        XCTAssertEqual(studio.fadeSeconds, 0)
        let reset = try await studio.renderedAudio()
        XCTAssertEqual(reset, factory)
        XCTAssertEqual(studio.settings, settings)
    }

    @MainActor
    func testOfflineRestorePreservesExactOriginalSourceAndEditRecipe() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        let source = try localSource()
        studio.load(source, name: "Unsaved source.wav")
        applyEdits(studio)

        await studio.restoreDefaultAudio()

        XCTAssertNil(studio.error)
        let backup = try XCTUnwrap(studio.lastRestoreBackup)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("source.f32le")), float32LE(source.samples))
        let convenience = try WaveAudio.decode(Data(contentsOf: backup.appendingPathComponent("source.wav")))
        XCTAssertEqual(convenience.sampleRate, source.sampleRate)
        XCTAssertEqual(convenience.samples.count, source.samples.count)
        let recipe = try JSONDecoder().decode(RecoveryRecipe.self, from: Data(contentsOf: backup.appendingPathComponent("edits.json")))
        XCTAssertEqual(recipe.version, 1)
        XCTAssertEqual(recipe.sampleEncoding, "float32-le")
        XCTAssertEqual(recipe.sampleRate, source.sampleRate)
        XCTAssertEqual(recipe.sampleCount, source.samples.count)
        XCTAssertEqual(recipe.name, "Unsaved source.wav")
        XCTAssertEqual(recipe.trimStart, 0.25)
        XCTAssertEqual(recipe.trimEnd, 0.75)
        XCTAssertEqual(recipe.gainDB, 3)
        XCTAssertTrue(recipe.normalize)
        XCTAssertEqual(recipe.fadeSeconds, 0.04)
        XCTAssertNil(studio.lastDeviceAudioBackup)
        let rendered = try await studio.renderedAudio()
        XCTAssertEqual(rendered, try FactoryAudio.wavData())
    }

    @MainActor
    func testConnectedRestoreWritesExactFactoryAndBacksUpDeviceWithoutChangingSettings() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = try WaveAudio.tone(hz: 400, seconds: 0.2).picoFoxWAV()
        let folder = try deviceFolder(audio: previous)
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        await studio.connect(folder)
        XCTAssertNil(studio.error)
        let source = try localSource()
        studio.load(source, name: "Unsaved source.wav")
        applyEdits(studio)
        studio.settings.callsign = "N1DRAFT"
        let draft = studio.settings
        let factory = try FactoryAudio.wavData()

        await studio.restoreDefaultAudio()

        XCTAssertNil(studio.error)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), factory)
        XCTAssertEqual(studio.device?.audio, factory)
        let deviceBackup = try XCTUnwrap(studio.lastDeviceAudioBackup)
        XCTAssertEqual(try Data(contentsOf: deviceBackup), previous)
        let localBackup = try XCTUnwrap(studio.lastRestoreBackup)
        XCTAssertEqual(try Data(contentsOf: localBackup.appendingPathComponent("source.f32le")), float32LE(source.samples))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), settingsBytes)
        XCTAssertEqual(studio.device?.settings, settingsBytes)
        XCTAssertEqual(studio.settings, draft)
        let rendered = try await studio.renderedAudio()
        XCTAssertEqual(rendered, factory)
        XCTAssertEqual(studio.fadeSeconds, 0)
        XCTAssertFalse(studio.busy)
    }

    @MainActor
    func testConnectedRestoreCreatesMissingAudioWithoutInventingAnOriginalBackup() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        await studio.connect(folder)
        XCTAssertNil(studio.audio)
        let settings = studio.settings

        await studio.restoreDefaultAudio()

        let factory = try FactoryAudio.wavData()
        XCTAssertNil(studio.error)
        XCTAssertNil(studio.lastRestoreBackup)
        XCTAssertNil(studio.lastDeviceAudioBackup)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), factory)
        XCTAssertEqual(studio.device?.audio, factory)
        XCTAssertEqual(studio.settings, settings)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), settingsBytes)
    }

    @MainActor
    func testUnavailableSelectedDeviceLoadsFactoryLocallyWithoutWritingDeviceFiles() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = try WaveAudio.tone(hz: 400, seconds: 0.2).picoFoxWAV()
        let folder = try deviceFolder(audio: previous)
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        await studio.connect(folder)
        let selected = try XCTUnwrap(studio.device)
        let source = try localSource()
        studio.load(source, name: "Unsaved source.wav")
        applyEdits(studio)
        studio.settings.callsign = "N1DRAFT"
        let draft = studio.settings
        let settingsURL = folder.appendingPathComponent("settings.txt")
        let heldSettingsURL = folder.appendingPathComponent("held-settings.txt")
        try FileManager.default.moveItem(at: settingsURL, to: heldSettingsURL)
        await studio.refreshConnection()
        XCTAssertFalse(studio.canSaveToDevice)

        await studio.restoreDefaultAudio()

        XCTAssertNil(studio.error)
        XCTAssertFalse(studio.deviceIsAvailable)
        XCTAssertFalse(studio.canSaveToDevice)
        XCTAssertEqual(studio.device?.bookmark, selected.bookmark)
        XCTAssertEqual(studio.device?.audio, previous)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertEqual(try Data(contentsOf: heldSettingsURL), settingsBytes)
        XCTAssertEqual(studio.settings, draft)
        XCTAssertTrue(studio.hasFactoryAudio)
        let rendered = try await studio.renderedAudio()
        XCTAssertEqual(rendered, try FactoryAudio.wavData())
        let recovery = try XCTUnwrap(studio.lastRestoreBackup)
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("source.f32le")), float32LE(source.samples))
        XCTAssertNil(studio.lastDeviceAudioBackup)
    }

    @MainActor
    func testOutsideAudioChangeRefusesRestoreAndPreservesCurrentEditor() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = try WaveAudio.tone(hz: 400, seconds: 0.2).picoFoxWAV()
        let folder = try deviceFolder(audio: previous)
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        await studio.connect(folder)
        let source = try localSource()
        studio.load(source, name: "Unsaved source.wav")
        applyEdits(studio)
        let settings = studio.settings
        // Another writer changes the original after the app took its connection snapshot.
        let outside = try WaveAudio.tone(hz: 900, seconds: 0.3).picoFoxWAV()
        try outside.write(to: folder.appendingPathComponent("audio.wav"), options: .atomic)

        await studio.restoreDefaultAudio()

        XCTAssertTrue(studio.error?.contains("changed outside") == true)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), outside)
        XCTAssertEqual(studio.device?.audio, previous)
        XCTAssertNil(studio.lastDeviceAudioBackup)
        XCTAssertNotNil(studio.lastRestoreBackup)
        XCTAssertEqual(studio.audio, source)
        XCTAssertEqual(studio.audioName, "Unsaved source.wav")
        assertEdits(studio)
        XCTAssertEqual(studio.settings, settings)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), settingsBytes)
        XCTAssertFalse(studio.busy)
    }

    @MainActor
    func testUnreadableOriginalRefusesRestoreWithoutReplacingLocalAudioOrFiles() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try deviceFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: false)
        let markerURL = audioURL.appendingPathComponent("original.txt")
        let marker = Data("Preserve the unreadable original.".utf8)
        try marker.write(to: markerURL)
        let studio = StudioModel(defaults: defaults)
        defer { cleanupBackups(studio) }
        await studio.connect(folder)
        XCTAssertNotNil(studio.device?.audioReadError)
        XCTAssertNil(studio.error)
        let source = try localSource()
        studio.load(source, name: "Unsaved source.wav")
        applyEdits(studio)
        let settings = studio.settings

        await studio.restoreDefaultAudio()

        XCTAssertTrue(studio.error?.contains("cannot be backed up safely") == true)
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
        XCTAssertNil(studio.lastRestoreBackup)
        XCTAssertNil(studio.lastDeviceAudioBackup)
        XCTAssertEqual(studio.audio, source)
        XCTAssertEqual(studio.audioName, "Unsaved source.wav")
        assertEdits(studio)
        XCTAssertEqual(studio.settings, settings)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), settingsBytes)
    }

    private var settingsBytes: Data {
        Data("# Original settings\nCALLSIGN=N0CALL\nFREQ_MHZ=146.565\nFUTURE_SETTING=keep\n".utf8)
    }

    private func deviceFolder(audio: Data? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try settingsBytes.write(to: folder.appendingPathComponent("settings.txt"))
        if let audio { try audio.write(to: folder.appendingPathComponent("audio.wav")) }
        return folder
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "PicoFox.FactoryRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func localSource() throws -> WaveAudio {
        let values: [Float] = [0.12345678, -0.87654321, 0.33333333, -0.0]
        return try WaveAudio(sampleRate: 48_000, samples: (0..<48_000).map { values[$0 % values.count] })
    }

    private func float32LE(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        }
        return result
    }

    @MainActor
    private func applyEdits(_ studio: StudioModel) {
        studio.trimStart = 0.25
        studio.trimEnd = 0.75
        studio.gainDB = 3
        studio.normalize = true
        studio.fadeSeconds = 0.04
    }

    @MainActor
    private func assertEdits(_ studio: StudioModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(studio.trimStart, 0.25, file: file, line: line)
        XCTAssertEqual(studio.trimEnd, 0.75, file: file, line: line)
        XCTAssertEqual(studio.gainDB, 3, file: file, line: line)
        XCTAssertTrue(studio.normalize, file: file, line: line)
        XCTAssertEqual(studio.fadeSeconds, 0.04, file: file, line: line)
    }

    @MainActor
    private func cleanupBackups(_ studio: StudioModel) {
        var folders = Set<URL>()
        if let folder = studio.lastRestoreBackup { folders.insert(folder) }
        if let file = studio.lastDeviceAudioBackup { folders.insert(file.deletingLastPathComponent()) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private struct RecoveryRecipe: Decodable {
        let version: Int
        let sampleEncoding: String
        let sampleRate: Int
        let sampleCount: Int
        let name: String
        let trimStart: Double
        let trimEnd: Double
        let gainDB: Double
        let normalize: Bool
        let fadeSeconds: Double
    }
}
