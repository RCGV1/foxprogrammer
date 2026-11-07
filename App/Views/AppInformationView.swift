// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI

struct AppInformationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var section = Information.privacy

    private enum Information: String, CaseIterable, Identifiable {
        case privacy = "Privacy", support = "Support", credits = "Credits"
        var id: Self { self }
        var resource: String { self == .privacy ? "Privacy" : "Support" }
        var url: URL {
            URL(string: self == .credits
                ? "https://creativecommons.org/licenses/by-nc-sa/4.0/"
                : "https://rcgv1.github.io/foxprogrammer/\(resource.lowercased()).html")!
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("FoxProgrammer").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Information", selection: $section) {
                ForEach(Information.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                Text(content).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            HStack {
                Text(version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("View on web", destination: section.url)
            }
        }
        .padding(20)
        .frame(idealWidth: 560, idealHeight: 620)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var content: String {
        if section == .credits {
            return "FoxProgrammer is a community project. Source code: GNU GPL version 3.\nhttps://github.com/RCGV1/foxprogrammer\n\nPicoFox is an AI6YM product. Hardware names identify compatibility.\n\nOriginal factory recording: AI6YM / Giorgi Enterprises LLC.\n\nCreative Commons Attribution-NonCommercial-ShareAlike 4.0 International. The upstream license and attribution are bundled with the recording. Its PCM samples are unchanged; WAV length fields were corrected."
        }
        guard let url = Bundle.main.url(forResource: section.resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Open the public \(section.rawValue.lowercased()) page using View on web."
        }
        return text
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}
