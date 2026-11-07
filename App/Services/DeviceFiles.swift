// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation
import PicoFoxCore

struct DeviceSnapshot: Sendable {
    var bookmark: Data
    var name: String
    var settings: Data
    var audio: Data?
    var audioReadError: String? = nil
}

/// All external I/O is serialized and coordinated. The editor operates on local snapshots.
actor DeviceFiles {
    private let maximumAudioBytes = 12_000_000
    private func scoped<T>(_ url: URL, operation: () throws -> T) throws -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try operation()
    }
    private func coordinate<T>(_ url: URL, writing: Bool, operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                outcome = Result { try operation(target) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                outcome = Result { try operation(target) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw PicoFoxError.invalid("File access was interrupted. Select the PicoFox folder again.") }
        return try outcome.get()
    }
    private func bookmark(_ url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    private func resolve(_ data: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw PicoFoxError.invalid("Folder permission expired. Select the PicoFox folder again.") }
        return url
    }
    func open(_ url: URL) throws -> DeviceSnapshot {
        try scoped(url) {
            let settingsURL = url.appendingPathComponent("settings.txt")
            let settings = try coordinate(settingsURL, writing: false) { try limitedRead($0, maximum: 64_000) }
            guard let text = String(data: settings, encoding: .utf8) else { throw PicoFoxError.invalid("settings.txt must be UTF-8 text.") }
            _ = try SettingsDocument(text: text)
            let audioURL = url.appendingPathComponent("audio.wav")
            var audio: Data?
            var audioReadError: String?
            if FileManager.default.fileExists(atPath: audioURL.path) {
                do {
                    audio = try coordinate(audioURL, writing: false) { try limitedRead($0, maximum: maximumAudioBytes) }
                } catch {
                    audioReadError = error.localizedDescription
                }
            }
            return DeviceSnapshot(bookmark: try bookmark(url), name: url.lastPathComponent, settings: settings,
                                  audio: audio, audioReadError: audioReadError)
        }
    }
    func reopen(_ data: Data) throws -> DeviceSnapshot { try open(resolve(data)) }
    /// Verify the authorized folder's settings without reading audio or changing files.
    func checkAvailability(bookmark data: Data) throws {
        let folder = try resolve(data)
        try scoped(folder) {
            let settings = try coordinate(folder.appendingPathComponent("settings.txt"), writing: false) {
                try limitedRead($0, maximum: 64_000)
            }
            guard let text = String(data: settings, encoding: .utf8) else {
                throw PicoFoxError.invalid("settings.txt must be UTF-8 text.")
            }
            _ = try SettingsDocument(text: text)
        }
    }
    private func limitedRead(_ url: URL, maximum: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximum else { throw PicoFoxError.invalid("\(url.lastPathComponent) is too large to open safely.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw PicoFoxError.invalid("File grew beyond the supported size.") }
        return data
    }
    func readImportedWAV(_ url: URL) throws -> Data {
        try scoped(url) { try coordinate(url, writing: false) { try limitedRead($0, maximum: 64_000_000) } }
    }
    func readImportedAudio(_ url: URL) throws -> WaveAudio {
        try scoped(url) { try coordinate(url, writing: false) { try AudioImport.decode($0) } }
    }
    func save(bookmark data: Data, filename: String, expected: Data?, replacement: Data) throws -> URL? {
        guard ["settings.txt", "audio.wav"].contains(filename) else { throw PicoFoxError.invalid("Unsupported device file.") }
        guard replacement.count <= maximumAudioBytes else { throw PicoFoxError.invalid("Audio exceeds the app’s 12 MB device-file limit.") }
        let folder = try resolve(data)
        return try scoped(folder) {
            try coordinate(folder.appendingPathComponent(filename), writing: true) { target in
                let exists = FileManager.default.fileExists(atPath: target.path)
                let current: Data?
                if exists {
                    do {
                        current = try limitedRead(target, maximum: maximumAudioBytes)
                    } catch {
                        throw PicoFoxError.invalid("Cannot save \(filename) because its existing contents could not be read. The original has not been changed and no backup was created. Copy or repair the device files before saving. \(error.localizedDescription)")
                    }
                } else { current = nil }
                guard current == expected else { throw PicoFoxError.invalid("\(filename) changed outside the app. Your draft is intact. Reopen the folder to load its current files before saving.") }
                var backupURL: URL?
                if let current {
                    let backupFolder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PicoFox/Backups/\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                    let backup = backupFolder.appendingPathComponent(filename)
                    try current.write(to: backup, options: .atomic)
                    backupURL = backup
                }
                try replacement.write(to: target, options: .atomic)
                guard try Data(contentsOf: target) == replacement else {
                    throw PicoFoxError.invalid("Read-back verification failed. The device may contain an incomplete file. Your original is in local Backups; reconnect before retrying.")
                }
                return backupURL
            }
        }
    }
}
