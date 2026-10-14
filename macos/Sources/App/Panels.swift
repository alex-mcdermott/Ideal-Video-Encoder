// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import IVECore
import UniformTypeIdentifiers

/// NSOpenPanel / NSSavePanel actions.
extension AppModel {
    func openAddPanel() {
        guard !isLocked else { return }
        let p = NSOpenPanel()
        p.title = "Add Clips"
        p.prompt = "Add"
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie, .folder]
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseLut() {
        let p = NSOpenPanel()
        p.title = "Choose a LUT"
        p.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        if !settings.lutPath.isEmpty { p.directoryURL = URL(fileURLWithPath: (settings.lutPath as NSString).deletingLastPathComponent) }
        guard p.runModal() == .OK, let url = p.url else { return }
        settings.lutPath = url.path
        settings.lutEnabled = true
        appendLog("LUT: \(url.path)")
    }

    /// Picking a file turns on "Replace with a music file"; the path isn't saved (as on Windows).
    func chooseMusic() {
        let p = NSOpenPanel()
        p.title = "Choose a music file"
        p.allowedContentTypes = SpeedAudio.musicExtensions.compactMap { UTType(filenameExtension: $0) } + [.audio]
        if !musicPath.isEmpty { p.directoryURL = URL(fileURLWithPath: (musicPath as NSString).deletingLastPathComponent) }
        guard p.runModal() == .OK, let url = p.url else { return }
        musicPath = url.path
        musicOn = true
        appendLog("Music: \(url.path)")
    }

    func chooseOutputFolder() {
        let p = NSOpenPanel()
        p.title = "Choose Output Folder"
        p.prompt = "Choose"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        let current = settings.outputFolder.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty { p.directoryURL = URL(fileURLWithPath: current) }
        if p.runModal() == .OK, let url = p.url { settings.outputFolder = url.path }
    }

    func chooseCsv() {
        let p = NSSavePanel()
        p.title = "CSV Log"
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = (settings.csvPath as NSString).lastPathComponent
        p.directoryURL = URL(fileURLWithPath: (settings.csvPath as NSString).deletingLastPathComponent)
        if p.runModal() == .OK, let url = p.url {
            settings.csvPath = url.path
            settings.csvEnabled = true
        }
    }

    func chooseTool(_ tool: Tool) -> String? {
        let p = NSOpenPanel()
        p.title = "Choose \(tool.rawValue)"
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = true
        p.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        return p.runModal() == .OK ? p.url?.path : nil
    }
}
