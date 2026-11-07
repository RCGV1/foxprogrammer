// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import Foundation
import PicoFoxCore

struct SpeechVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String
}

/// Generates an editable local source rather than speaking through the device's speakers.
@MainActor
final class SpeechAudio: NSObject {
    private var cachedVoices: [SpeechVoice]?
    var voices: [SpeechVoice] {
        if let cachedVoices { return cachedVoices }
        let available = installedVoices().map { SpeechVoice(id: $0.identifier, name: $0.name, language: $0.language) }
        cachedVoices = available
        return available
    }

    private let timeout: Duration
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: SpeechCompletionDelegate?
    private var accumulator: SpeechBufferAccumulator?
    private var pending: CheckedContinuation<WaveAudio, any Error>?
    private var requestID: UUID?
    private var deadline: Task<Void, Never>?

    init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
        super.init()
    }

    func generate(text: String, voiceID: String?, rate: Double = 0.5) async throws -> WaveAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PicoFoxError.invalid("Enter some text to create speech.") }
        guard text.count <= 2000, text.utf8.count <= 64_000 else {
            throw PicoFoxError.invalid("Use no more than 2,000 characters for speech.")
        }
        guard rate.isFinite, Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate) ~= rate else {
            throw PicoFoxError.invalid("Choose a valid speech rate between 0 and 1.")
        }
        try Task.checkCancellation()
        guard pending == nil else { throw PicoFoxError.invalid("Speech is already being created.") }
        let available = installedVoices()
        let voice: AVSpeechSynthesisVoice
        if let voiceID, !voiceID.isEmpty {
            guard let selected = available.first(where: { $0.identifier == voiceID }) else {
                throw PicoFoxError.invalid("That voice is unavailable. Choose an installed voice.")
            }
            voice = selected
        } else {
            let preferred = AVSpeechSynthesisVoice(language: nil)
            let language = AVSpeechSynthesisVoice.currentLanguageCode()
            guard let selected = available.first(where: { $0.identifier == preferred?.identifier }) ??
                    available.first(where: { $0.language == language }) ??
                    available.first(where: { $0.language.split(separator: "-").first == language.split(separator: "-").first }) ??
                    available.first else {
                throw PicoFoxError.invalid("No installed speech voice is available on this device.")
            }
            voice = selected
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let collector = SpeechBufferAccumulator()
                let completion: @Sendable (Result<WaveAudio, any Error>) -> Void = { [weak self] result in
                    Task { @MainActor [weak self] in self?.complete(id: id, result: result) }
                }
                let listener = SpeechCompletionDelegate(accumulator: collector, completion: completion)
                let engine = AVSpeechSynthesizer()
                let utterance = AVSpeechUtterance(string: trimmed)
                utterance.voice = voice
                utterance.rate = Float(rate)
                utterance.preUtteranceDelay = 0
                utterance.postUtteranceDelay = 0
                pending = continuation
                requestID = id
                accumulator = collector
                delegate = listener
                synthesizer = engine
                engine.delegate = listener
                deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.complete(id: id, result: .failure(PicoFoxError.invalid("Speech creation timed out. Try a shorter message or another installed voice.")))
                }
                // Build the callback outside MainActor isolation: AVFoundation may invoke it
                // on its own queue, and its AVAudioBuffer must never cross an actor boundary.
                engine.write(utterance, toBufferCallback: Self.callback(accumulator: collector, completion: completion))
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func cancel() {
        guard let requestID else { return }
        cancel(id: requestID)
    }

    private func cancel(id: UUID) { complete(id: id, result: .failure(CancellationError())) }

    private func complete(id: UUID, result: Result<WaveAudio, any Error>) {
        guard requestID == id, let continuation = pending else { return }
        requestID = nil
        pending = nil
        deadline?.cancel()
        deadline = nil
        accumulator?.cancel()
        accumulator = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        delegate = nil
        continuation.resume(with: result)
    }

    private func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.identifier < $1.identifier
        }
    }

    nonisolated private static func callback(
        accumulator: SpeechBufferAccumulator,
        completion: @escaping @Sendable (Result<WaveAudio, any Error>) -> Void
    ) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in if let result = accumulator.consume(buffer) { completion(result) } }
    }

    /// Converts actual framework PCM buffers; exposed internally for storage-free adapter tests.
    nonisolated static func monoAudio(from buffer: AVAudioPCMBuffer) throws -> WaveAudio {
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard rate.isFinite, (1000...192000).contains(rate), abs(rate - rate.rounded()) < 0.001,
              frames > 0, frames <= 12_000_000, frames <= Int(rate) * 600, (1...8).contains(channels),
              buffer.stride == (buffer.format.isInterleaved ? channels : 1) else {
            throw PicoFoxError.invalid("The system voice returned invalid PCM audio.")
        }
        let bytesPerSample = try pcmBytesPerSample(buffer.format.commonFormat)
        guard frames * channels * bytesPerSample <= 64_000_000 else {
            throw PicoFoxError.invalid("The speech audio buffer is too large.")
        }
        let floats = buffer.floatChannelData
        let shorts = buffer.int16ChannelData
        let integers = buffer.int32ChannelData
        guard floats != nil || shorts != nil || integers != nil else {
            throw PicoFoxError.invalid("The system voice returned an unsupported PCM layout.")
        }
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channels {
                let offset = frame * buffer.stride
                let value: Double
                if let floats { value = Double(floats[channel][offset]) }
                else if let shorts { value = Double(shorts[channel][offset]) / 32768 }
                else if let integers { value = Double(integers[channel][offset]) / 2147483648 }
                else { throw PicoFoxError.invalid("The speech audio buffer is unreadable.") }
                guard value.isFinite else { throw PicoFoxError.invalid("The system voice returned nonfinite audio.") }
                sum += value / Double(channels)
            }
            // Keep finite peaks above full scale intact. The edit/encoding pipeline applies
            // uniform headroom; clipping here would permanently distort the generated source.
            samples[frame] = Float(sum)
        }
        return try WaveAudio(sampleRate: Int(rate.rounded()), samples: samples)
    }

    nonisolated static func pcmBytesPerSample(_ format: AVAudioCommonFormat) throws -> Int {
        switch format {
        case .pcmFormatFloat32, .pcmFormatInt32: return 4
        case .pcmFormatInt16: return 2
        default: throw PicoFoxError.invalid("The system voice returned an unsupported PCM format.")
        }
    }
}

/// Callback-owned storage. Its lock keeps framework buffers and sample ordering off MainActor.
final class SpeechBufferAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Int?
    private var rawBytes = 0
    private var finished = false

    func consume(_ buffer: AVAudioBuffer) -> Result<WaveAudio, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                throw PicoFoxError.invalid("The system voice returned unsupported audio.")
            }
            if pcm.frameLength == 0 { return finishLocked() }
            let chunk = try SpeechAudio.monoAudio(from: pcm)
            guard rate == nil || rate == chunk.sampleRate else {
                throw PicoFoxError.invalid("The system voice changed sample rates during speech creation.")
            }
            let bytes = chunk.samples.count * Int(pcm.format.channelCount) * (try SpeechAudio.pcmBytesPerSample(pcm.format.commonFormat))
            let count = samples.count + chunk.samples.count
            guard count <= 12_000_000, count <= chunk.sampleRate * 600, rawBytes + bytes <= 64_000_000 else {
                throw PicoFoxError.invalid("Speech audio exceeds the 10-minute or memory limit.")
            }
            rate = chunk.sampleRate
            rawBytes += bytes
            samples.append(contentsOf: chunk.samples)
            return nil
        } catch {
            finished = true
            samples.removeAll()
            return .failure(error)
        }
    }

    func finish() -> Result<WaveAudio, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? nil : finishLocked()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        samples.removeAll()
    }

    private func finishLocked() -> Result<WaveAudio, any Error> {
        finished = true
        defer { samples.removeAll() }
        guard let rate, !samples.isEmpty else {
            return .failure(PicoFoxError.invalid("The selected voice did not create audio. Try another installed voice."))
        }
        return Result { try WaveAudio(sampleRate: rate, samples: samples) }
    }
}

private final class SpeechCompletionDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let accumulator: SpeechBufferAccumulator
    private let completion: @Sendable (Result<WaveAudio, any Error>) -> Void

    init(accumulator: SpeechBufferAccumulator, completion: @escaping @Sendable (Result<WaveAudio, any Error>) -> Void) {
        self.accumulator = accumulator
        self.completion = completion
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if let result = accumulator.finish() { completion(result) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        accumulator.cancel()
        completion(.failure(CancellationError()))
    }
}
