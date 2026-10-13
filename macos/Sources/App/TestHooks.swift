// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Test-only: when IVE_SNAPSHOT_DIR is set, the app writes PNGs of its own windows on request
/// (`touch <dir>/request-<name>`), so layout can be checked without Screen Recording permission.
/// Does nothing when the variable is absent.
@MainActor
enum TestHooks {
    static func start() {
        // IVE_APPEARANCE=dark|light forces the app's appearance (what the system setting does to every app)
        switch ProcessInfo.processInfo.environment["IVE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let dir = ProcessInfo.processInfo.environment["IVE_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for req in names where req.hasPrefix("request-") {
                    try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(req))
                    snapshot(name: String(req.dropFirst("request-".count)), to: dir)
                }
            }
        }
    }

    static func snapshot(name: String, to dir: String) {
        var i = 0
        for w in NSApp.windows where w.isVisible {
            guard let view = w.contentView?.superview ?? w.contentView else { continue }
            let rect = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            view.cacheDisplay(in: rect, to: rep)
            let suffix = i == 0 ? "" : "-\(i)"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
            i += 1
        }
    }
}
