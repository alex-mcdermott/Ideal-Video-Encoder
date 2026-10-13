// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import IVECore
import SwiftUI

@main
struct IdealVideoEncoderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Ideal Video Encoder", id: "main") {
            ContentView()
                .environment(delegate.model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Clips…") { delegate.model.openAddPanel() }
                    .keyboardShortcut("o")
                    .disabled(delegate.model.isLocked)
            }
            CommandMenu("Queue") {
                Button("Preview Selected Clip") { delegate.model.preview.start() }
                    .disabled(delegate.model.items.isEmpty)
                Button("Play / Pause Preview") { delegate.model.preview.togglePlay() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Stop Preview") { delegate.model.preview.stop() }
                Divider()
                Button("Start") { delegate.model.startPressed() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(delegate.model.runState == .running || delegate.model.runState == .analysing)
                Button("Cancel") { delegate.model.cancelPressed() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(delegate.model.runState == .idle)
                Divider()
                Button("Clear Queue") { delegate.model.clear() }
                    .disabled(delegate.model.isLocked || delegate.model.items.isEmpty)
            }
            CommandGroup(after: .appSettings) {
                Button("Tools Setup…") { delegate.model.showSetup = true }
            }
        }

        Settings {
            ToolSettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        TestHooks.start()
    }

    /// Finder "Open With", files dropped on the Dock icon, and `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ask before quitting while a conversion or analysis runs; then stop it cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isLocked else { model.saveSettings(); return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A conversion or analysis is running."
        alert.informativeText = "Stop it and quit? The file being encoded will be deleted."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
