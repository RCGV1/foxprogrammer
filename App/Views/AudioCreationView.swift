// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI

enum AudioCreationKind { case tone, speech }

struct AudioCreationView: View {
    @Bindable var studio: StudioModel
    var focusedInput: FocusState<StudioInput?>.Binding
    @Binding var kind: AudioCreationKind?
    @State private var frequency = 600.0
    @State private var seconds = 3.0
    @State private var text = ""
    @State private var voiceID = ""
    @State private var rate = 0.5

    var body: some View {
        if let kind {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(kind == .tone ? "Custom tone" : "Text to speech").font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark") { focusedInput.wrappedValue = nil; self.kind = nil }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Close audio creator")
                }
                if kind == .tone { toneControls } else { speechControls }
            }
            .padding(.vertical, 8)
        }
    }
    private var toneControls: some View {
        Group {
            LabeledContent("Frequency · Hz") {
                TextField("100–2000", value: $frequency, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing).frame(maxWidth: 120).labelsHidden()
                    .accessibilityLabel("Tone frequency in hertz").focused(focusedInput, equals: .toneFrequency)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            Slider(value: $frequency, in: 100...2000, step: 1).labelsHidden().accessibilityLabel("Tone frequency")
            if !frequency.isFinite || !(100...2000).contains(frequency) {
                Label("Tone frequency must be 100–2000 Hz.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toneFrequencyWarning")
            }
            LabeledContent("Duration · seconds") {
                TextField("0.1–60", value: $seconds, format: .number.precision(.fractionLength(1...2)))
                    .multilineTextAlignment(.trailing).frame(maxWidth: 120).labelsHidden()
                    .accessibilityLabel("Tone duration in seconds").focused(focusedInput, equals: .toneDuration)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            Button("Generate tone", systemImage: "waveform.path") {
                focusedInput.wrappedValue = nil
                let hz = frequency, duration = seconds
                Task { if await studio.generateTone(hz: hz, seconds: duration), kind == .tone { kind = nil } }
            }
            .disabled(!frequency.isFinite || !(100...2000).contains(frequency) || !seconds.isFinite || !(0.1...60).contains(seconds))
        }
    }
    private var speechControls: some View {
        Group {
            TextField("Text to read aloud", text: $text, axis: .vertical)
                .lineLimit(3...6).focused(focusedInput, equals: .speech)
                .accessibilityLabel("Speech text")
            Picker("Voice", selection: $voiceID) {
                Text("System default").tag("")
                ForEach(studio.speech.voices) { voice in
                    Text("\(voice.name) · \(voice.language)").tag(voice.id)
                }
            }
            Slider(value: $rate, in: 0.25...0.65) {
                Text("Speech speed")
            } minimumValueLabel: { Image(systemName: "tortoise") }
              maximumValueLabel: { Image(systemName: "hare") }
              .accessibilityLabel("Speech speed")
            Button("Generate speech", systemImage: "text.bubble") {
                focusedInput.wrappedValue = nil
                let words = text, voice = voiceID.isEmpty ? nil : voiceID, speed = rate
                Task { if await studio.generateSpeech(text: words, voiceID: voice, rate: speed), kind == .speech { kind = nil } }
            }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 2000)
            if text.count > 2000 { Text("Use 2,000 characters or fewer.").font(.caption).foregroundStyle(.orange) }
        }
    }
}
