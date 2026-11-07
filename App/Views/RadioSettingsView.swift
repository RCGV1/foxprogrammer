// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI
import PicoFoxCore

struct RadioSettingsView: View {
    @Bindable var studio: StudioModel
    var focusedInput: FocusState<StudioInput?>.Binding
    var openFolder: () -> Void
    var export: () -> Void
    var body: some View {
        Form {
            Section {
                LabeledContent("PicoFox", value: studio.device == nil ? "Not connected" : studio.deviceIsAvailable ? studio.device!.name : "Disconnected")
                Button(studio.device == nil ? "Connect PicoFox" : "Change folder", systemImage: "folder", action: openFolder).disabled(studio.capture.isRecording)
            } footer: {
                if studio.device != nil, !studio.deviceIsAvailable {
                    Text("Reconnect USB. Your edits are kept.")
                } else if studio.device?.audioReadError != nil {
                    Text("audio.wav is unreadable. Settings are available.")
                }
                #if os(iOS)
                if studio.device == nil {
                    Text("Browse → Locations → NO NAME. Select once to reconnect automatically.")
                }
                #endif
            }
            Section("Radio") {
                LabeledContent("Callsign") {
                    TextField("1–11 letters or digits", text: $studio.settings.callsign)
                        .labelsHidden()
                        .accessibilityLabel("Callsign")
                        .multilineTextAlignment(.trailing).autocorrectionDisabled()
                        .frame(maxWidth: 180)
                        .onChange(of: studio.settings.callsign) { _, value in studio.settings.callsign = value.uppercased() }
                        .accessibilityIdentifier("callsign")
                        .focused(focusedInput, equals: .callsign)
                        #if os(iOS)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.done)
                        .onSubmit { focusedInput.wrappedValue = nil }
                        #endif
                }
                Picker("ITU zone", selection: $studio.settings.ituZone) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                }
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Frequency · MHz") {
                        TextField("MHz", value: $studio.settings.frequencyMHz, format: .number.precision(.fractionLength(3...6)))
                            .labelsHidden()
                            .accessibilityLabel("Frequency in megahertz")
                            .multilineTextAlignment(.trailing).frame(maxWidth: 180).accessibilityIdentifier("frequency")
                            .focused(focusedInput, equals: .frequency)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            .submitLabel(.done)
                            .onSubmit { focusedInput.wrappedValue = nil }
                            #endif
                    }
                    if let issue = studio.settings.frequencyIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("frequencyWarning")
                    }
                }
            }
            Section("Transmission") {
                Stepper("Duty cycle: \(studio.settings.dutyCycle)%", value: $studio.settings.dutyCycle, in: 0...100)
                LabeledContent("Power", value: "≈\(String(format: "%.2f", PowerLevel.milliwatts(attenuation: studio.settings.attenuation))) mW")
                Slider(value: Binding(
                    get: { Double(127 - min(127, max(0, studio.settings.attenuation))) },
                    set: { studio.settings.attenuation = PowerLevel.attenuation(sliderStep: $0) }
                ), in: 0...127, step: 1) {
                    Text("Output power")
                } minimumValueLabel: {
                    Text("0.04").font(.caption)
                } maximumValueLabel: {
                    Text("65 mW").font(.caption)
                }
                .labelsHidden()
                .accessibilityLabel("Output power")
                .accessibilityValue("Approximately \(PowerLevel.milliwatts(attenuation: studio.settings.attenuation)) milliwatts")
            }
            DisclosureGroup("Morse ID") {
                Stepper("Speed: \(studio.settings.morseWPM) WPM", value: $studio.settings.morseWPM, in: 1...30)
                Stepper("Spacing: \(studio.settings.farnsworthWPM) WPM", value: $studio.settings.farnsworthWPM, in: 1...255)
                Stepper("Tone: \(studio.settings.toneHz) Hz", value: $studio.settings.toneHz, in: 100...2000, step: 50)
                Stepper("Volume: \(studio.settings.toneVolume)%", value: $studio.settings.toneVolume, in: 1...100)
            }
            Section {
                if !studio.settings.callsign.isEmpty,
                   let issue = studio.settings.issues.first(where: { $0 != studio.settings.frequencyIssue }) {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                Button("Save to PicoFox", systemImage: "externaldrive") { Task { await studio.saveSettingsToDevice() } }
                    .disabled(!studio.canSaveToDevice || !studio.settings.issues.isEmpty)
                Button("Export settings.txt", systemImage: "square.and.arrow.up", action: export).disabled(!studio.settings.issues.isEmpty)
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.borderless)
        .disabled(studio.capture.isRecording)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}
