// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import AVFoundation
import Combine
import Foundation
import Observation
import PicoFoxCore

/// An Apple playback adapter. The caller supplies the rendered PCM WAV.
@MainActor @Observable
final class AudioPlayback {
    enum State: Equatable {
        case stopped, playing, paused
    }

    private(set) var state = State.stopped
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0
    var isPlaying: Bool { state == .playing }
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlaybackDelegate?
    @ObservationIgnored private var playbackID: UUID?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var ownsPlaybackSession = false
    private let transitionSeconds = 0.008

    init() {
        #if os(iOS)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { self?.pause() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue else { return }
                MainActor.assumeIsolated { self?.pause() }
            }
            .store(in: &subscriptions)
        #endif
    }

    func play(data: Data) throws {
        stop()
        let next = try AVAudioPlayer(data: data)
        let (id, nextDelegate) = makeDelegate()
        next.delegate = nextDelegate
        next.volume = 0
        do {
            try activateSession()
            guard next.prepareToPlay(), next.play() else {
                throw PicoFoxError.invalid("Audio playback could not start. Check the selected output device.")
            }
        } catch {
            next.delegate = nil
            next.stop()
            deactivateSessionIfIdle()
            throw error
        }
        player = next
        delegate = nextDelegate
        playbackID = id
        duration = next.duration
        currentTime = 0
        state = .playing
        next.setVolume(1, fadeDuration: transitionSeconds)
        startProgressUpdates()
    }

    func pause() {
        guard state == .playing, let player, let id = playbackID else { return }
        cancelProgressUpdates()
        pauseTask?.cancel()
        currentTime = boundedTime(player.currentTime)
        state = .paused
        player.setVolume(0, fadeDuration: transitionSeconds)
        pauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.008)) }
            catch { return }
            guard let self, self.playbackID == id, self.state == .paused else { return }
            player.pause()
            self.currentTime = self.boundedTime(player.currentTime)
            self.pauseTask = nil
            self.deactivateSessionIfIdle()
        }
    }

    func resume() throws {
        guard let player else { throw PicoFoxError.invalid("Load audio before playing.") }
        guard state != .playing else { return }
        pauseTask?.cancel()
        pauseTask = nil
        if currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        // A finish callback already queued before Resume belongs to the previous run.
        let (id, nextDelegate) = makeDelegate()
        player.delegate = nextDelegate
        delegate = nextDelegate
        playbackID = id
        do {
            try activateSession()
            player.volume = 0
            guard player.play() else { throw PicoFoxError.invalid("Audio playback could not resume.") }
        } catch {
            player.pause()
            state = .paused
            deactivateSessionIfIdle()
            throw error
        }
        state = .playing
        player.setVolume(1, fadeDuration: transitionSeconds)
        startProgressUpdates()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        if state == .paused {
            pauseTask?.cancel()
            pauseTask = nil
            player.pause()
            deactivateSessionIfIdle()
        }
        let destination = boundedTime(seconds)
        player.currentTime = destination
        currentTime = destination
    }

    func stop() {
        cancelProgressUpdates()
        pauseTask?.cancel()
        pauseTask = nil
        let previous = player
        previous?.delegate = nil
        player = nil
        delegate = nil
        playbackID = nil
        state = .stopped
        currentTime = 0
        duration = 0
        guard let previous, previous.isPlaying else {
            previous?.stop()
            deactivateSessionIfIdle()
            return
        }
        previous.setVolume(0, fadeDuration: transitionSeconds)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.008))
            // This is the old player, so replacing the track cannot stop the new one.
            previous.stop()
            self?.deactivateSessionIfIdle()
        }
    }

    private func boundedTime(_ time: Double) -> Double { max(0, min(duration, time)) }

    private func makeDelegate() -> (UUID, PlaybackDelegate) {
        let id = UUID()
        return (id, PlaybackDelegate(id: id) { [weak self] id, event in
            Task { @MainActor [weak self] in self?.handle(event, for: id) }
        })
    }

    private func startProgressUpdates() {
        cancelProgressUpdates()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return }
                guard let self, self.state == .playing, let player = self.player else { return }
                self.currentTime = self.boundedTime(player.currentTime)
                if !player.isPlaying {
                    // Completion is confirmed by the delegate; an unexpected stop is paused.
                    self.state = .paused
                    self.cancelProgressUpdates()
                    self.deactivateSessionIfIdle()
                    return
                }
            }
        }
    }

    private func cancelProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func handle(_ event: PlaybackDelegate.Event, for id: UUID) {
        guard playbackID == id, let player else { return }
        // AVAudioPlayer may have been resumed before a previous finish was delivered.
        if case .finished = event, player.isPlaying { return }
        cancelProgressUpdates()
        pauseTask?.cancel()
        pauseTask = nil
        switch event {
        case .finished(true): currentTime = duration
        default: currentTime = boundedTime(player.currentTime)
        }
        player.delegate = nil
        player.stop()
        self.player = nil
        delegate = nil
        playbackID = nil
        state = .stopped
        deactivateSessionIfIdle()
        switch event {
        case .finished(false): onError?("Audio playback stopped before the end of the file.")
        case .failed(let message): onError?("Audio playback failed: \(message)")
        case .finished(true): break
        }
    }

    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        ownsPlaybackSession = true
        #endif
    }

    private func deactivateSessionIfIdle() {
        #if os(iOS)
        guard ownsPlaybackSession, state != .playing, player?.isPlaying != true else { return }
        ownsPlaybackSession = false
        let session = AVAudioSession.sharedInstance()
        // Recording may already have taken ownership of the shared session.
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Each player gets a separate token, so queued callbacks cannot mutate a replacement.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    enum Event: Sendable {
        case finished(Bool)
        case failed(String)
    }
    private let id: UUID
    private let receive: @Sendable (UUID, Event) -> Void

    init(id: UUID, receive: @escaping @Sendable (UUID, Event) -> Void) {
        self.id = id
        self.receive = receive
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        receive(id, .finished(flag))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        receive(id, .failed(error?.localizedDescription ?? "The audio could not be decoded."))
    }
}
