// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI
import UniformTypeIdentifiers
import PicoFoxCore

enum StudioPage: String, CaseIterable, Identifiable {
    case settings = "Settings", audio = "Audio"
    var id: String { rawValue }
    var icon: String { self == .settings ? "slider.horizontal.3" : "waveform" }
}

enum StudioInput: Hashable {
    case callsign, frequency, toneFrequency, toneDuration, speech, trimStart, trimEnd
}

struct StudioView: View {
    @Bindable var studio: StudioModel
    @State private var page: StudioPage? = .settings
    @State private var importKind = ImportKind.folder
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportName = "audio.wav"
    @State private var confirmOpen = false
    @State private var confirmReconnect = false
    @State private var showingInformation = false
    @FocusState private var focusedInput: StudioInput?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    enum ImportKind { case folder, audio }
    var body: some View {
        shell
            .sheet(isPresented: $showingInformation) { AppInformationView() }
            .onChange(of: page) { focusedInput = nil }
            .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .folder ? [.folder] : [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { if importKind == .folder { await studio.connect(url) } else { await studio.importAudio(url) } }
                case .failure(let error): reportFileError(error)
                }
            }
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportName == "audio.wav" ? .wav : .plainText, defaultFilename: exportName) { result in
                switch result {
                case .success: break
                case .failure(let error): reportFileError(error)
                }
            }
            .alert("Couldn’t finish", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
                Button("OK") { studio.error = nil }
            } message: { Text(studio.error ?? "") }
            .confirmationDialog("Replace your current edits with the folder’s files?", isPresented: $confirmOpen, titleVisibility: .visible) {
                Button("Choose folder", role: .destructive) { beginImport(.folder) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Reload files and discard current edits?", isPresented: $confirmReconnect, titleVisibility: .visible) {
                Button("Reload", role: .destructive) { Task { await studio.reconnect() } }
                Button("Cancel", role: .cancel) {}
            }
    }
    @ViewBuilder private var shell: some View {
        #if os(iOS)
        if sizeClass == .compact {
            TabView(selection: $page) {
                ForEach(StudioPage.allCases) { item in
                    NavigationStack { content(item).navigationTitle(item.rawValue).toolbar { toolbar(for: item) } }
                        .tabItem { Label(item.rawValue, systemImage: item.icon) }.tag(Optional(item))
                }
            }
        } else { splitView }
        #else
        splitView
        #endif
    }
    private var splitView: some View {
        NavigationSplitView {
            List(StudioPage.allCases, selection: $page) { item in
                NavigationLink(value: item) { Label(item.rawValue, systemImage: item.icon) }.tag(item)
            }
                .navigationTitle("FoxProgrammer")
                .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            content(page ?? .settings).navigationTitle((page ?? .settings).rawValue).toolbar { toolbar(for: page ?? .settings) }
        }
    }
    @ToolbarContentBuilder private func toolbar(for item: StudioPage) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack {
                if studio.device != nil {
                    Image(systemName: studio.deviceIsAvailable ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .foregroundStyle(studio.deviceIsAvailable ? Color.secondary : .orange)
                        .accessibilityLabel(studio.deviceIsAvailable ? "PicoFox connected" : "PicoFox disconnected. Edits kept.")
                        .help(studio.deviceIsAvailable ? "PicoFox connected" : "PicoFox disconnected. Edits kept.")
                }
                Menu {
                    Button("Open PicoFox folder", systemImage: "folder") { requestFolder() }
                    Button("Reopen last folder", systemImage: "arrow.clockwise") { confirmReconnect = true }
                    if studio.device != nil { Button("Close folder", systemImage: "eject") { studio.disconnect() } }
                    Button("Keep settings draft", systemImage: "doc") { studio.saveDraft() }
                    Divider()
                    Button("Privacy & Support", systemImage: "info.circle") { showingInformation = true }
                } label: { Label("Files", systemImage: "folder") }
                .help("Files")
                .accessibilityLabel("Files")
                .disabled(studio.busy || studio.capture.isRecording)
            }
        }
    }
    @ViewBuilder private func content(_ page: StudioPage) -> some View {
        Group {
            switch page {
            case .settings: RadioSettingsView(studio: studio, focusedInput: $focusedInput, openFolder: requestFolder, export: exportSettings)
            case .audio: AudioEditorView(studio: studio, focusedInput: $focusedInput, importAudio: { beginImport(.audio) }, exportAudio: exportAudio)
            }
        }
        .disabled(studio.busy)
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if (self.page ?? .settings) == page, focusedInput != nil {
                HStack {
                    Spacer()
                    Button("Done") { focusedInput = nil }
                        .fixedSize()
                        .frame(minWidth: 60, minHeight: 44)
                        .accessibilityIdentifier("keyboardDone")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            status
        }
    }
    @ViewBuilder private var status: some View {
        if studio.busy {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(studio.generatingSpeech ? "Generating speech…" : "Working…")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if studio.generatingSpeech { Button("Cancel") { studio.speech.cancel() } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityElement(children: .contain)
        }
    }
    private func requestFolder() {
        if studio.device != nil || studio.hasAudio || !studio.settings.callsign.isEmpty { confirmOpen = true }
        else { beginImport(.folder) }
    }
    private func reportFileError(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
        studio.error = error.localizedDescription
    }
    private func beginImport(_ kind: ImportKind) { importKind = kind; importing = true }
    private func exportSettings() {
        do { exportFile = ExportFile(data: try studio.settingsData()); exportName = "settings.txt"; exporting = true }
        catch { studio.error = error.localizedDescription }
    }
    private func exportAudio() {
        Task { if let file = await studio.prepareAudioExport() { exportFile = file; exportName = "audio.wav"; exporting = true } }
    }
}
