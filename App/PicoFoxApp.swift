// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import SwiftUI
#if os(macOS)
import AppKit
import Combine
#endif

@main
struct PicoFoxApp: App {
    @State private var studio = StudioModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            StudioView(studio: studio)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 520)
                #endif
                .tint(.orange)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await studio.restore()
                    await studio.monitorConnection()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { studio.capture.finish(); studio.stop() }
                }
                #if os(macOS)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
                    .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification))) { _ in
                    if scenePhase == .active { Task { await studio.refreshConnection() } }
                }
                #endif
        }
        .defaultSize(width: 1120, height: 800)
    }
}
