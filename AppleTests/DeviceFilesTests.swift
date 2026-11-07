// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import XCTest
import PicoFoxCore
@testable import PicoFoxMac

final class DeviceFilesTests: XCTestCase {
    func testSnapshotSaveBackupReadbackAndConflict() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data("CALLSIGN=N0CALL\nFREQ_MHZ=146.565\n".utf8)
        try original.write(to: folder.appendingPathComponent("settings.txt"))
        let audio = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        try audio.write(to: folder.appendingPathComponent("audio.wav"))
        let files = DeviceFiles()
        let opened = try await files.open(folder)
        XCTAssertEqual(opened.settings, original)
        XCTAssertEqual(opened.audio, audio)
        XCTAssertNil(opened.audioReadError)
        let reopened = try await files.reopen(opened.bookmark)
        XCTAssertEqual(reopened.settings, original)
        let replacement = Data("CALLSIGN=N1TEST\nFREQ_MHZ=146.565\n".utf8)
        let backup = try await files.save(bookmark: opened.bookmark, filename: "settings.txt", expected: original, replacement: replacement)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), replacement)
        let backupURL = try XCTUnwrap(backup)
        defer { try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        do {
            _ = try await files.save(bookmark: opened.bookmark, filename: "settings.txt", expected: original, replacement: original)
            XCTFail("Must refuse to overwrite an external change")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed outside")) }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("settings.txt")), replacement)
        do {
            _ = try await files.save(bookmark: opened.bookmark, filename: "../other.txt", expected: nil, replacement: original)
            XCTFail("Must reject arbitrary filenames")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported")) }
    }
    func testMissingAudioMayBeCreatedAndUnpluggedFolderFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("CALLSIGN=N0CALL\n".utf8).write(to: folder.appendingPathComponent("settings.txt"))
        let files = DeviceFiles()
        let opened = try await files.open(folder)
        XCTAssertNil(opened.audio)
        XCTAssertNil(opened.audioReadError)
        let wave = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        let backup = try await files.save(bookmark: opened.bookmark, filename: "audio.wav", expected: nil, replacement: wave)
        XCTAssertNil(backup)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.wav")), wave)
        try FileManager.default.removeItem(at: folder)
        do { _ = try await files.reopen(opened.bookmark); XCTFail("Deleted or unplugged folder must fail") } catch {}
    }
    func testUnrelatedFolderAndCorruptSettingsAreRejected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = DeviceFiles()
        do { _ = try await files.open(folder); XCTFail("No settings.txt") } catch {}
        try Data("FREQ_MHZ=garbage\n".utf8).write(to: folder.appendingPathComponent("settings.txt"))
        do { _ = try await files.open(folder); XCTFail("Malformed known field") } catch { XCTAssertTrue(error.localizedDescription.contains("FREQ_MHZ")) }
    }

    func testUnreadableAudioStillOpensSettingsAndCannotBeOverwritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalSettings = Data("CALLSIGN=N0CALL\nFREQ_MHZ=146.565\n".utf8)
        let settingsURL = folder.appendingPathComponent("settings.txt")
        try originalSettings.write(to: settingsURL)

        // A directory at the WAV path deterministically fails a file read, regardless of privileges.
        let audioURL = folder.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: false)
        let markerURL = audioURL.appendingPathComponent("original.txt")
        let marker = Data("Preserve the unreadable original.".utf8)
        try marker.write(to: markerURL)

        let files = DeviceFiles()
        let opened = try await files.open(folder)
        XCTAssertEqual(opened.settings, originalSettings)
        XCTAssertNil(opened.audio)
        XCTAssertNotNil(opened.audioReadError)
        let reopened = try await files.reopen(opened.bookmark)
        XCTAssertEqual(reopened.settings, originalSettings)
        XCTAssertNil(reopened.audio)
        XCTAssertNotNil(reopened.audioReadError)

        let backupsRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicoFox/Backups")
        func backupNames() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: backupsRoot.path)) ?? [])
        }
        let backupsBefore = backupNames()
        let replacement = try WaveAudio.tone(seconds: 0.1).picoFoxWAV()
        do {
            _ = try await files.save(bookmark: opened.bookmark, filename: "audio.wav",
                                     expected: opened.audio, replacement: replacement)
            XCTFail("An unreadable original must never be treated as a missing audio file")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("existing contents could not be read"))
            XCTAssertTrue(error.localizedDescription.contains("no backup was created"))
        }
        XCTAssertEqual(backupNames(), backupsBefore)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
        XCTAssertEqual(try Data(contentsOf: settingsURL), originalSettings)
    }

    func testAvailabilityDoesNotDependOnMissingOrUnreadableAudio() async throws {
        let folder = try availabilityFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let settingsURL = folder.appendingPathComponent("settings.txt")
        let original = try Data(contentsOf: settingsURL)
        let files = DeviceFiles()
        let authorized = try await files.open(folder)
        XCTAssertNil(authorized.audio)
        try await files.checkAvailability(bookmark: authorized.bookmark)

        let audioURL = folder.appendingPathComponent("audio.wav")
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: false)
        let markerURL = audioURL.appendingPathComponent("original.txt")
        let marker = Data("Do not read or change device audio during an availability check.".utf8)
        try marker.write(to: markerURL)

        try await files.checkAvailability(bookmark: authorized.bookmark)

        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
    }

    func testAvailabilityDetectsSettingsDisappearanceAndReturnWithSameFolderIdentity() async throws {
        let folder = try availabilityFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = DeviceFiles()
        let authorized = try await files.open(folder)
        let settingsURL = folder.appendingPathComponent("settings.txt")
        let heldURL = folder.appendingPathComponent("held-settings.txt")
        try await files.checkAvailability(bookmark: authorized.bookmark)
        try FileManager.default.moveItem(at: settingsURL, to: heldURL)

        do {
            try await files.checkAvailability(bookmark: authorized.bookmark)
            XCTFail("A cached bookmark must not report availability while settings.txt is missing")
        } catch {}

        // Retain the authorized folder's identity, rather than substituting a new folder at its path.
        try FileManager.default.moveItem(at: heldURL, to: settingsURL)
        try await files.checkAvailability(bookmark: authorized.bookmark)
        XCTAssertEqual(try Data(contentsOf: settingsURL), authorized.settings)
    }

    func testAvailabilityRejectsDeletedFolderAndInvalidBookmark() async throws {
        let folder = try availabilityFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = DeviceFiles()
        let authorized = try await files.open(folder)
        try FileManager.default.removeItem(at: folder)

        do {
            try await files.checkAvailability(bookmark: authorized.bookmark)
            XCTFail("A deleted or unplugged folder must not remain available")
        } catch {}
        do {
            try await files.checkAvailability(bookmark: Data("invalid bookmark".utf8))
            XCTFail("An invalid bookmark cannot authorize an availability check")
        } catch {}
    }

    func testAvailabilityValidatesCurrentSettingsAndEnforcesReadLimit() async throws {
        let folder = try availabilityFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = DeviceFiles()
        let authorized = try await files.open(folder)
        let settingsURL = folder.appendingPathComponent("settings.txt")
        try Data("FREQ_MHZ=garbage\n".utf8).write(to: settingsURL)
        do {
            try await files.checkAvailability(bookmark: authorized.bookmark)
            XCTFail("Malformed current settings must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("FREQ_MHZ")) }

        try Data([0xFF, 0xFE]).write(to: settingsURL)
        do {
            try await files.checkAvailability(bookmark: authorized.bookmark)
            XCTFail("Invalid UTF-8 must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("UTF-8")) }

        try Data(repeating: 0x20, count: 64_001).write(to: settingsURL)
        do {
            try await files.checkAvailability(bookmark: authorized.bookmark)
            XCTFail("The settings read must stay within its 64 KB limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }

        try authorized.settings.write(to: settingsURL)
        try await files.checkAvailability(bookmark: authorized.bookmark)
        XCTAssertEqual(try Data(contentsOf: settingsURL), authorized.settings)
    }

    private func availabilityFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("CALLSIGN=N0CALL\nFREQ_MHZ=146.565\n".utf8)
            .write(to: folder.appendingPathComponent("settings.txt"))
        return folder
    }
}
