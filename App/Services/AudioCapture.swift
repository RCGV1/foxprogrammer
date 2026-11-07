// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import Observation
import Foundation
import PicoFoxCore

@MainActor @Observable
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsed = 0.0
    var onError: ((String) -> Void)?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var onFinished: ((URL) -> Void)?
    @ObservationIgnored private var pendingStart: UUID?
    @ObservationIgnored private var isFinishing = false
    #if os(iOS)
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    #endif

    func start(onFinished: @escaping (URL) -> Void) async throws {
        // Keep the previous recorder until its delegate confirms a closed, valid file.
        guard recorder == nil, pendingStart == nil else { return }
        let attempt = UUID()
        pendingStart = attempt
        defer { if pendingStart == attempt { pendingStart = nil } }
        #if os(iOS)
        let allowed = await AVAudioApplication.requestRecordPermission()
        #else
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard pendingStart == attempt else { return }
        guard allowed else { throw PicoFoxError.invalid("Allow microphone access in system Privacy settings to record audio.") }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picofox-\(UUID().uuidString).wav")
        var candidate: AVAudioRecorder?
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let device = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            candidate = device
            device.delegate = self
            guard device.prepareToRecord(), device.record(forDuration: 120) else {
                throw PicoFoxError.invalid("Recording could not start. Check the selected microphone.")
            }
            recorder = device
            destination = url
            self.onFinished = onFinished
            elapsed = 0
            isFinishing = false
            isRecording = true
            #if os(iOS)
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.destination == url else { return }
                    self.finishAfterInterruption(url: url)
                }
            }
            #endif
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                          self.destination == url, let recorder = self.recorder else { return }
                    self.elapsed = max(self.elapsed, recorder.currentTime)
                }
            }
        } catch {
            candidate?.delegate = nil
            candidate?.stop()
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
            throw error
        }
    }

    func finish() {
        pendingStart = nil
        guard isRecording, !isFinishing, let recorder else { return }
        elapsed = max(elapsed, recorder.currentTime)
        isFinishing = true
        timer?.cancel()
        timer = nil
        // stop closes the WAV; only the completion delegate decides whether to import it.
        recorder.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            self?.complete(url: url, error: flag ? nil : "Recording failed. Please try again.")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let url = recorder.url
        let message = error.map { "Recording failed: \($0.localizedDescription)" } ?? "Recording failed while writing audio."
        Task { @MainActor [weak self] in self?.complete(url: url, error: message) }
    }

    private func finishAfterInterruption(url: URL) {
        guard destination == url else { return }
        finish()
        // AVAudioRecorder does not send its finish delegate when the session is interrupted.
        // stop closes the file; complete verifies that it contains readable audio frames.
        complete(url: url, error: nil)
    }

    private func complete(url completedURL: URL, error: String?) {
        guard let recorder, destination == completedURL else { return }
        elapsed = max(elapsed, recorder.currentTime)
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        timer?.cancel()
        timer = nil
        isFinishing = false
        isRecording = false
        let url = destination
        destination = nil
        let callback = onFinished
        onFinished = nil
        #if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        #endif
        deactivateSession()
        var failure = error
        if failure == nil {
            do {
                let file = try AVAudioFile(forReading: completedURL)
                if file.length == 0 { failure = "No audio was recorded. Please try again." }
            } catch { failure = "Recording could not be read: \(error.localizedDescription)" }
        }
        if let failure {
            if let url { try? FileManager.default.removeItem(at: url) }
            onError?(failure)
        } else if let url {
            callback?(url)
        }
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
