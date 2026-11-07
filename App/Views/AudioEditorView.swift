// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI
import PicoFoxCore

struct AudioEditorView: View {
    @Bindable var studio: StudioModel
    var focusedInput: FocusState<StudioInput?>.Binding
    var importAudio: () -> Void
    var exportAudio: () -> Void
    @State private var resumeAfterScrubbing = false
    @State private var confirmDefaultAudio = false
    @State private var creationKind: AudioCreationKind?
    var body: some View {
        Form {
            Section {
                if let issue = studio.device?.audioReadError {
                    Label("Device audio unreadable. Local editing is available.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(issue)
                }
                ViewThatFits(in: .horizontal) {
                    audioActions.labelStyle(.titleAndIcon)
                    compactAudioActions.labelStyle(.titleAndIcon)
                }
                AudioCreationView(studio: studio, focusedInput: focusedInput, kind: $creationKind)
                Button("Restore default audio", systemImage: "arrow.counterclockwise") { confirmDefaultAudio = true }
                    .disabled(studio.capture.isRecording)
                if studio.capture.isRecording {
                    Label("Recording · \(studio.capture.elapsed, specifier: "%.1f") s", systemImage: "record.circle.fill")
                        .foregroundStyle(.red).monospacedDigit()
                }
                if let audio = studio.audio {
                    Text(studio.audioName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    WaveformView(peaks: studio.peaks, start: studio.trimStart / audio.duration, end: studio.trimEnd / audio.duration)
                        .frame(height: 120)
                        .accessibilityLabel("Waveform, selection \(studio.trimStart, specifier: "%.2f") to \(studio.trimEnd, specifier: "%.2f") seconds")
                    Picker("Playback quality", selection: $studio.previewMode) {
                        ForEach(PreviewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(studio.capture.isRecording)
                    HStack {
                        Text("\(studio.playback.currentTime, specifier: "%.1f") / \(max(0, studio.trimEnd - studio.trimStart), specifier: "%.1f") s")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        if studio.playback.state != .stopped {
                            Button { studio.stop() } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(minWidth: actionTargetSize, minHeight: actionTargetSize)
                                    .contentShape(Rectangle())
                            }.labelStyle(.iconOnly)
                        }
                        Button { Task { await studio.preview() } } label: {
                            Label(studio.isPlaying ? "Pause" : "Play", systemImage: studio.isPlaying ? "pause.fill" : "play.fill")
                                .frame(minWidth: actionTargetSize, minHeight: actionTargetSize)
                                .contentShape(Rectangle())
                        }.disabled(!studio.validTrim || studio.capture.isRecording)
                    }
                    Slider(value: Binding(get: { studio.playback.currentTime }, set: { studio.playback.seek(to: $0) }),
                           in: 0...max(0.001, studio.playback.duration), onEditingChanged: { dragging in
                        if dragging { resumeAfterScrubbing = studio.isPlaying; studio.playback.pause() }
                        else if resumeAfterScrubbing {
                            do { try studio.playback.resume() } catch { studio.error = error.localizedDescription }
                            resumeAfterScrubbing = false
                        }
                    })
                    .labelsHidden()
                    .disabled(studio.playback.duration <= 0 || studio.capture.isRecording)
                    .accessibilityLabel("Playback position")
                } else if creationKind == nil {
                    ContentUnavailableView("No audio", systemImage: "waveform", description: Text("Record, import, or generate audio."))
                }
            } footer: {
                if studio.hasFactoryAudio {
                    Link("Default recording: AI6YM · CC BY-NC-SA 4.0", destination: URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/")!)
                }
            }
            if let audio = studio.audio {
                Section("Trim") {
                    LabeledContent("Start · seconds") {
                        TextField("Start", value: $studio.trimStart, format: .number.precision(.fractionLength(3)))
                            .labelsHidden()
                            .accessibilityLabel("Trim start in seconds")
                            .focused(focusedInput, equals: .trimStart)
                            .onSubmit { focusedInput.wrappedValue = nil }
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            .submitLabel(.done)
                            #endif
                            .multilineTextAlignment(.trailing).frame(maxWidth: 130)
                    }
                    Slider(value: $studio.trimStart, in: 0...audio.duration).labelsHidden().accessibilityLabel("Trim start")
                    LabeledContent("End · seconds") {
                        TextField("End", value: $studio.trimEnd, format: .number.precision(.fractionLength(3)))
                            .labelsHidden()
                            .accessibilityLabel("Trim end in seconds")
                            .focused(focusedInput, equals: .trimEnd)
                            .onSubmit { focusedInput.wrappedValue = nil }
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            .submitLabel(.done)
                            #endif
                            .multilineTextAlignment(.trailing).frame(maxWidth: 130)
                    }
                    Slider(value: $studio.trimEnd, in: 0...audio.duration).labelsHidden().accessibilityLabel("Trim end")
                }.disabled(studio.capture.isRecording)
                Section {
                    LabeledContent("Gain", value: "\(String(format: "%+.1f", studio.gainDB)) dB")
                    Slider(value: $studio.gainDB, in: -24...24, step: 0.5).labelsHidden().accessibilityLabel("Gain in decibels")
                    Toggle("Normalize", isOn: $studio.normalize)
                    LabeledContent("Fade in / out", value: "\(String(format: "%.2f", studio.fadeSeconds)) s")
                    Slider(value: $studio.fadeSeconds, in: 0...2, step: 0.01).labelsHidden().accessibilityLabel("Fade duration")
                    Button("Reset edits") { studio.resetEdits() }
                }.disabled(studio.capture.isRecording)
                Section {
                    if !studio.validTrim { Text("End must be after start and within the audio.").font(.caption).foregroundStyle(.orange) }
                    Button("Save to PicoFox", systemImage: "externaldrive") { Task { await studio.saveAudioToDevice() } }
                        .disabled(!studio.canSaveToDevice || studio.device?.audioReadError != nil || !studio.validTrim || studio.capture.isRecording)
                    Button("Export audio.wav", systemImage: "square.and.arrow.up", action: exportAudio).disabled(!studio.validTrim || studio.capture.isRecording)
                } footer: {
                    if studio.device != nil, !studio.deviceIsAvailable { Text("PicoFox disconnected. Your edits are kept.") }
                    Text("5 kHz · mono · 16-bit PCM")
                }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.borderless)
        .confirmationDialog("Restore default audio?", isPresented: $confirmDefaultAudio, titleVisibility: .visible) {
            Button("Restore default audio", role: .destructive) { Task { await studio.restoreDefaultAudio() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if studio.canSaveToDevice {
                Text("Replaces device audio and current edits. Backups are saved first.")
            } else if studio.hasAudio {
                Text("Replaces your editor audio. A local backup is saved first.")
            } else {
                Text("Load the original PicoFox recording for playback or export.")
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onChange(of: creationKind) { focusedInput.wrappedValue = nil }
        .onChange(of: studio.trimStart) { studio.stop() }
        .onChange(of: studio.trimEnd) { studio.stop() }
        .onChange(of: studio.gainDB) { studio.stop() }
        .onChange(of: studio.normalize) { studio.stop() }
        .onChange(of: studio.fadeSeconds) { studio.stop() }
        .onChange(of: studio.previewMode) { studio.stop() }
    }
    private var audioActions: some View {
        HStack(spacing: 12) {
            recordAction; Spacer(minLength: 0)
            importAction; Spacer(minLength: 0)
            toneAction; Spacer(minLength: 0)
            speechAction
        }
    }
    private var compactAudioActions: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
            GridRow {
                recordAction.frame(maxWidth: .infinity, alignment: .leading)
                importAction.frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                toneAction.frame(maxWidth: .infinity, alignment: .leading)
                speechAction.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var recordAction: some View {
        Button { Task { await studio.record() } } label: {
            Label(studio.capture.isRecording ? "Stop" : "Record", systemImage: studio.capture.isRecording ? "stop.circle.fill" : "mic.fill")
                .frame(minWidth: actionTargetSize, minHeight: actionTargetSize).contentShape(Rectangle())
        }.foregroundStyle(.red).fixedSize()
    }
    private var importAction: some View {
        Button(action: importAudio) {
            Label("Import", systemImage: "square.and.arrow.down")
                .frame(minWidth: actionTargetSize, minHeight: actionTargetSize).contentShape(Rectangle())
        }.fixedSize().disabled(studio.capture.isRecording)
    }
    private var toneAction: some View {
        Button { creationKind = creationKind == .tone ? nil : .tone } label: {
            Label("Tone", systemImage: "waveform.path")
                .frame(minWidth: actionTargetSize, minHeight: actionTargetSize).contentShape(Rectangle())
        }.fixedSize().disabled(studio.capture.isRecording)
    }
    private var speechAction: some View {
        Button { creationKind = creationKind == .speech ? nil : .speech } label: {
            Label("Speech", systemImage: "text.bubble")
                .frame(minWidth: actionTargetSize, minHeight: actionTargetSize).contentShape(Rectangle())
        }.fixedSize().disabled(studio.capture.isRecording)
    }
    private var actionTargetSize: CGFloat? {
        #if os(iOS)
        44
        #else
        nil
        #endif
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let start: Double
    let end: Double
    var body: some View {
        Canvas { context, size in
            let lower = start.isFinite ? max(0, min(1, start)) : 0
            let upper = end.isFinite ? max(0, min(1, end)) : 0
            context.fill(Path(CGRect(x: size.width * lower, y: 0, width: max(0, upper - lower) * size.width, height: size.height)), with: .color(.orange.opacity(0.08)))
            guard !peaks.isEmpty else { return }
            let stride = size.width / Double(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let x = Double(index) * stride
                let height = max(2, Double(peak) * (size.height - 24))
                let selected = Double(index) / Double(peaks.count) >= lower && Double(index) / Double(peaks.count) <= upper
                context.fill(Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2, width: max(1, stride * 0.65), height: height), cornerRadius: 1), with: .color(selected ? .orange : .gray.opacity(0.4)))
            }
        }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
