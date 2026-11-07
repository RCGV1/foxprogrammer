// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI
import AVFoundation
import PicoFoxCore
import UniformTypeIdentifiers

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case fullQuality = "Full quality", picoFox = "PicoFox"
    var id: String { rawValue }
}

enum AudioSourceStyle { case standard, factory, speech }

@MainActor @Observable
final class StudioModel {
    var settings = PicoFoxSettings()
    var audio: WaveAudio?
    var audioName = "No audio loaded"
    var trimStart = 0.0
    var trimEnd = 0.0
    var gainDB = 0.0
    var normalize = false
    var fadeSeconds = 0.02
    var peaks: [Float] = []
    var device: DeviceSnapshot?
    private(set) var deviceIsAvailable = false
    var busy = false
    var error: String?
    var previewMode: PreviewMode = .fullQuality
    private(set) var lastRestoreBackup: URL?
    private(set) var lastDeviceAudioBackup: URL?
    let playback = AudioPlayback()
    let capture = AudioCapture()
    let speech = SpeechAudio()
    private(set) var generatingSpeech = false
    var isPlaying: Bool { playback.isPlaying }
    private var document = try! SettingsDocument()
    private var pendingPreview: Task<Data, Error>?
    private var pendingTone: Task<WaveAudio, Error>?
    private var playbackGeneration = 0
    private var sourceRevision = 0
    private var sourceStyle = AudioSourceStyle.standard
    private struct PreviewKey: Equatable {
        let sourceRevision: Int
        let start: Double
        let end: Double
        let gain: Double
        let normalize: Bool
        let fade: Double
        let mode: PreviewMode
    }
    private var cachedPreview: (key: PreviewKey, data: Data)?
    private let files = DeviceFiles()
    private let defaults: UserDefaults
    private var restored = false
    private var automaticReconnectSuppressed = false
    private var checkingConnection = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playback.onError = { [weak self] message in self?.error = message }
        capture.onError = { [weak self] message in self?.error = message }
    }
    var hasAudio: Bool { audio != nil }
    var canSaveToDevice: Bool { device != nil && deviceIsAvailable }
    var hasFactoryAudio: Bool { audio != nil && sourceStyle == .factory }
    var validTrim: Bool { audio != nil && trimStart >= 0 && trimEnd > trimStart && trimEnd <= (audio?.duration ?? 0) + 0.000001 }
    var estimatedBytes: Int {
        let seconds = trimEnd - trimStart
        guard seconds.isFinite, seconds >= 0, seconds <= 600 else { return 0 }
        return Int(seconds * 10000) + 44
    }
    var settingsChanged: Bool { guard let device else { return true }; return (try? settingsData()) != device.settings }
    private var draftURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicoFox")
        return folder.appendingPathComponent("draft.json")
    }
    func restore() async {
        guard !restored else { return }; restored = true
        do {
            if FileManager.default.fileExists(atPath: draftURL.path) {
                settings = try JSONDecoder().decode(PicoFoxSettings.self, from: Data(contentsOf: draftURL))
            }
        } catch { self.error = "Could not restore the local draft: \(error.localizedDescription)" }
    }
    func saveDraft() {
        do {
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: draftURL, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ url: URL) async {
        await perform {
            let snapshot = try await self.files.open(url)
            let parsed = try SettingsDocument(text: String(decoding: snapshot.settings, as: UTF8.self))
            self.stop()
            self.device = snapshot
            self.deviceIsAvailable = true
            self.document = parsed
            self.settings = parsed.settings
            self.audio = nil; self.peaks = []; self.audioName = snapshot.audioReadError == nil ? "No audio.wav on device" : "Device audio unavailable"
            if let data = snapshot.audio {
                do {
                    let decoded = try await Task.detached { try WaveAudio.decodePicoFox(data) }.value
                    self.load(decoded, name: "audio.wav")
                } catch { self.error = "Settings opened, but audio.wav could not be decoded: \(error.localizedDescription). Import a replacement WAV to repair it." }
            }
            self.defaults.set(snapshot.bookmark, forKey: "PicoFoxFolder")
            self.automaticReconnectSuppressed = false
        }
    }
    func reconnect() async {
        guard let bookmark = defaults.data(forKey: "PicoFoxFolder") else { error = "Choose a PicoFox folder first."; return }
        await perform {
            let snapshot = try await self.files.reopen(bookmark)
            // Reopening needs the same loading behavior, without nesting the busy operation.
            let parsed = try SettingsDocument(text: String(decoding: snapshot.settings, as: UTF8.self))
            self.document = parsed; self.settings = parsed.settings; self.device = snapshot
            self.deviceIsAvailable = true
            self.stop(); self.audio = nil; self.peaks = []; self.audioName = snapshot.audioReadError == nil ? "No audio.wav on device" : "Device audio unavailable"
            if let data = snapshot.audio {
                do {
                    let decoded = try await Task.detached { try WaveAudio.decodePicoFox(data) }.value
                    self.load(decoded, name: "audio.wav")
                } catch { self.error = "Settings reopened, but audio.wav could not be decoded: \(error.localizedDescription). Import a replacement WAV to repair it." }
            }
            self.automaticReconnectSuppressed = false
        }
    }
    private var automaticReconnectAllowed: Bool {
        !automaticReconnectSuppressed && device == nil && settings == PicoFoxSettings() &&
        audio == nil && !capture.isRecording && playback.state == .stopped
    }
    /// Retry only the folder the person already authorized, while the editor is untouched.
    func reconnectIfNeeded() async {
        guard !busy, automaticReconnectAllowed,
              let bookmark = defaults.data(forKey: "PicoFoxFolder") else { return }
        do {
            // Missing media is checked silently, without flashing the loading indicator.
            try await files.checkAvailability(bookmark: bookmark)
            guard !Task.isCancelled, !busy, automaticReconnectAllowed else { return }
            busy = true
            defer { busy = false }
            let snapshot = try await files.reopen(bookmark)
            let parsed = try SettingsDocument(text: String(decoding: snapshot.settings, as: UTF8.self))
            var decoded: WaveAudio?
            var audioDecodeFailed = false
            if let data = snapshot.audio {
                do { decoded = try await Task.detached { try WaveAudio.decodePicoFox(data) }.value }
                catch { audioDecodeFailed = true }
            }
            // An edit or an explicit Close can arrive while external I/O or decoding awaits.
            guard !Task.isCancelled, automaticReconnectAllowed else { return }
            stop()
            device = snapshot
            deviceIsAvailable = true
            document = parsed
            settings = parsed.settings
            peaks = []
            audioName = snapshot.audioReadError == nil ? "No audio.wav on device" : "Device audio unavailable"
            if let decoded { load(decoded, name: "audio.wav") }
            if audioDecodeFailed { audioName = "Device audio unavailable" }
        } catch is CancellationError {
        } catch {
            // A missing saved folder is normal while PicoFox is unplugged.
        }
    }
    /// Recheck only the authorized folder. Never reload the local editor on a hot-plug.
    func refreshConnection() async {
        guard !busy, !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        guard let selected = device else { await reconnectIfNeeded(); return }
        let available: Bool
        do { try await files.checkAvailability(bookmark: selected.bookmark); available = true }
        catch { available = false }
        guard !Task.isCancelled, device?.bookmark == selected.bookmark else { return }
        deviceIsAvailable = available
    }
    /// The scene owns cancellation, so no probes run while the iOS app is inactive.
    func monitorConnection() async {
        while !Task.isCancelled {
            await refreshConnection()
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }
    func disconnect() {
        automaticReconnectSuppressed = true
        device = nil
        deviceIsAvailable = false
    }
    func importAudio(_ url: URL) async {
        await perform {
            let decoded = try await self.files.readImportedAudio(url)
            self.load(decoded, name: url.lastPathComponent)
        }
    }
    func load(_ value: WaveAudio, name: String, style: AudioSourceStyle = .standard) {
        stop(); sourceRevision += 1; cachedPreview = nil
        sourceStyle = style
        audio = value; audioName = name; peaks = value.peaks()
        trimStart = 0; trimEnd = value.duration
        gainDB = style == .speech ? -6 : 0
        normalize = style == .speech
        fadeSeconds = style == .factory ? 0 : 0.02
    }
    func record() async {
        if capture.isRecording { capture.finish(); return }
        await perform {
            self.stop()
            try await self.capture.start { [weak self] url in
                Task { await self?.importRecording(url) }
            }
        }
    }
    private func importRecording(_ url: URL) async {
        await perform {
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try await self.files.readImportedWAV(url)
            let decoded = try await Task.detached { try WaveAudio.decode(data) }.value
            self.load(decoded, name: "Recording.wav")
        }
    }
    func generateTone() {
        do { load(try WaveAudio.tone(), name: "600 Hz test tone") }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func generateTone(hz: Double, seconds: Double) async -> Bool {
        var generated = false
        await perform {
            self.stop()
            let generation = self.playbackGeneration
            let task = Task.detached(priority: .userInitiated) { try WaveAudio.tone(hz: hz, seconds: seconds) }
            self.pendingTone = task
            defer { self.pendingTone = nil }
            let tone = try await task.value
            guard generation == self.playbackGeneration else { return }
            self.load(tone, name: "\(hz.formatted(.number.precision(.fractionLength(0...2)))) Hz tone")
            generated = true
        }
        return generated
    }
    @discardableResult
    func generateSpeech(text: String, voiceID: String?, rate: Double) async -> Bool {
        var generated = false
        await perform {
            self.stop()
            self.generatingSpeech = true
            defer { self.generatingSpeech = false }
            let audio = try await self.speech.generate(text: text, voiceID: voiceID, rate: rate)
            self.load(audio, name: "Speech · \(text.prefix(40))", style: .speech)
            generated = true
        }
        return generated
    }
    func restoreDefaultAudio() async {
        await perform {
            guard !self.capture.isRecording else { throw PicoFoxError.invalid("Stop recording before restoring default audio.") }
            if self.canSaveToDevice, self.device?.audioReadError != nil {
                throw PicoFoxError.invalid("The existing device audio cannot be backed up safely. Close the folder to load and export the default audio locally.")
            }
            let data = try FactoryAudio.wavData()
            let factory = try await Task.detached { try WaveAudio.decode(data) }.value
            let recovery = try await self.backupEditorForRestore()
            self.lastRestoreBackup = recovery
            self.lastDeviceAudioBackup = nil
            if let device = self.device, self.canSaveToDevice {
                self.lastDeviceAudioBackup = try await self.files.save(bookmark: device.bookmark, filename: "audio.wav",
                                                                      expected: device.audio, replacement: data)
                self.device?.audio = data
            }
            self.load(factory, name: "PicoFox default audio", style: .factory)
        }
    }
    private struct AudioRecovery: Codable, Sendable {
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
    private func backupEditorForRestore() async throws -> URL? {
        guard let audio else { return nil }
        let folder = backupFolder().appendingPathComponent(UUID().uuidString)
        let recovery = AudioRecovery(version: 1, sampleEncoding: "float32-le", sampleRate: audio.sampleRate,
                                     sampleCount: audio.samples.count, name: audioName, trimStart: trimStart,
                                     trimEnd: trimEnd, gainDB: gainDB, normalize: normalize, fadeSeconds: fadeSeconds)
        return try await Task.detached {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Apple arm64/x86_64 platforms store Float as little-endian IEEE 754 binary32.
            try audio.samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("source.f32le"), options: .atomic) }
            try audio.pcm16WAV().write(to: folder.appendingPathComponent("source.wav"), options: .atomic)
            try JSONEncoder().encode(recovery).write(to: folder.appendingPathComponent("edits.json"), options: .atomic)
            return folder
        }.value
    }
    func resetEdits() { if let audio { load(audio, name: audioName, style: sourceStyle) } }
    func settingsData() throws -> Data { var doc = document; doc.settings = settings; return try doc.encoded() }
    func renderedAudio() async throws -> Data {
        guard let audio, validTrim else { throw PicoFoxError.invalid("Load audio and select a nonempty trim range.") }
        if sourceStyle == .factory, trimStart == 0, trimEnd == audio.duration, gainDB == 0, !normalize, fadeSeconds == 0 {
            return try FactoryAudio.wavData()
        }
        let start = trimStart, end = trimEnd, gain = gainDB, normalized = normalize, fade = fadeSeconds
        return try await Task.detached(priority: .userInitiated) {
            try audio.edited(start: start, end: end, gainDB: gain, normalize: normalized, fadeSeconds: fade).picoFoxWAV()
        }.value
    }
    private func renderedPreview() async throws -> Data {
        guard let audio, validTrim else { throw PicoFoxError.invalid("Select a nonempty audio range.") }
        let key = PreviewKey(sourceRevision: sourceRevision, start: trimStart, end: trimEnd,
                             gain: gainDB, normalize: normalize, fade: fadeSeconds, mode: previewMode)
        if let cachedPreview, cachedPreview.key == key { return cachedPreview.data }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let edited = try audio.edited(start: key.start, end: key.end, gainDB: key.gain,
                                          normalize: key.normalize, fadeSeconds: key.fade)
            let data = try AudioPreview.render(edited, radio: key.mode == .picoFox)
            try Task.checkCancellation()
            return data
        }
        pendingPreview = task
        let data = try await task.value
        pendingPreview = nil
        if data.count <= 32_000_000 { cachedPreview = (key, data) }
        return data
    }
    func preview() async {
        guard !capture.isRecording else { return }
        if playback.state == .playing { playback.pause(); return }
        if playback.state == .paused {
            do { try playback.resume() } catch { self.error = error.localizedDescription }
            return
        }
        await perform {
            let generation = self.playbackGeneration
            let data = try await self.renderedPreview()
            guard generation == self.playbackGeneration else { return }
            try self.playback.play(data: data)
        }
    }
    func stop() {
        playbackGeneration += 1
        speech.cancel()
        pendingTone?.cancel(); pendingTone = nil
        pendingPreview?.cancel(); pendingPreview = nil
        playback.stop()
    }
    func saveSettingsToDevice() async {
        await perform {
            guard let device = self.device else { throw PicoFoxError.invalid("Select the PicoFox folder first.") }
            guard self.canSaveToDevice else { throw PicoFoxError.invalid("Reconnect PicoFox before saving. Your edits are kept locally.") }
            let data = try self.settingsData()
            _ = try await self.files.save(bookmark: device.bookmark, filename: "settings.txt", expected: device.settings, replacement: data)
            self.device?.settings = data
            self.document = try SettingsDocument(text: String(decoding: data, as: UTF8.self))
        }
    }
    func saveAudioToDevice() async {
        await perform {
            guard let device = self.device else { throw PicoFoxError.invalid("Select the PicoFox folder first.") }
            guard self.canSaveToDevice else { throw PicoFoxError.invalid("Reconnect PicoFox before saving. Your edits are kept locally.") }
            guard device.audioReadError == nil else {
                throw PicoFoxError.invalid("The existing device audio cannot be read safely. Export a local WAV instead.")
            }
            let data = try await self.renderedAudio()
            _ = try await self.files.save(bookmark: device.bookmark, filename: "audio.wav", expected: device.audio, replacement: data)
            self.device?.audio = data
        }
    }
    func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await operation() } catch is CancellationError { } catch {
            self.error = error.localizedDescription
            busy = false
            await refreshConnection()
        }
    }
    func prepareAudioExport() async -> ExportFile? {
        var file: ExportFile?
        await perform { file = ExportFile(data: try await self.renderedAudio()) }
        return file
    }
    func backupFolder() -> URL { draftURL.deletingLastPathComponent().appendingPathComponent("Backups") }
}
