// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Tool: String, CaseIterable, Sendable, Identifiable {
    case ffmpeg, ffprobe, exiftool
    public var id: String { rawValue }
}

public struct ToolPaths: Sendable, Equatable {
    public var ffmpeg: String
    public var ffprobe: String
    public var exiftool: String
    public init(ffmpeg: String, ffprobe: String, exiftool: String) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.exiftool = exiftool
    }
    public subscript(tool: Tool) -> String {
        switch tool { case .ffmpeg: ffmpeg; case .ffprobe: ffprobe; case .exiftool: exiftool }
    }
}

/// GUI apps don't inherit the shell PATH: look in Homebrew's folders first, then PATH.
public enum ToolLocator {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public static func locate(_ tool: Tool, override: String? = nil,
                              path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            return fm.isExecutableFile(atPath: o) ? o : nil
        }
        let dirs = searchDirectories + (path ?? "").split(separator: ":").map(String.init)
        for d in dirs where !d.isEmpty {
            let candidate = (d as NSString).appendingPathComponent(tool.rawValue)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func locateAll(settings: AppSettings) -> (paths: [Tool: String], missing: [Tool]) {
        var found: [Tool: String] = [:]
        var missing: [Tool] = []
        let overrides: [Tool: String?] = [.ffmpeg: settings.ffmpegPath, .ffprobe: settings.ffprobePath, .exiftool: settings.exiftoolPath]
        for t in Tool.allCases {
            if let p = locate(t, override: overrides[t] ?? nil) { found[t] = p } else { missing.append(t) }
        }
        return (found, missing)
    }
}

/// What the installed tools can do, and what to tell the user when something is missing.
public struct ToolReport: Sendable, Equatable {
    public static let requiredEncoders = ["libx265", "libsvtav1"]
    public static let requiredFilters = ["zscale", "lut3d", "lutyuv", "libvmaf"]
    /// Used by Auto CRF / Auto grain; present in every normal build, checked anyway.
    public static let otherFilters = ["signalstats", "hqdn3d", "psnr"]

    public var paths: [Tool: String] = [:]
    public var missingTools: [Tool] = []
    public var ffmpegVersion: String?
    public var encoders: Set<String> = []
    public var filters: Set<String> = []

    public init() {}

    public var toolPaths: ToolPaths? {
        guard let a = paths[.ffmpeg], let b = paths[.ffprobe], let c = paths[.exiftool] else { return nil }
        return ToolPaths(ffmpeg: a, ffprobe: b, exiftool: c)
    }
    public var missingEncoders: [String] { paths[.ffmpeg] == nil ? [] : Self.requiredEncoders.filter { !encoders.contains($0) } }
    public var missingFilters: [String] {
        paths[.ffmpeg] == nil ? [] : (Self.requiredFilters + Self.otherFilters).filter { !filters.contains($0) }
    }
    public var hasZscale: Bool { filters.contains("zscale") }
    public var hasVmaf: Bool { filters.contains("libvmaf") }
    public var isComplete: Bool { missingTools.isEmpty && missingEncoders.isEmpty && missingFilters.isEmpty }

    public struct Problem: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var explanation: String
        public var fix: String
    }

    static let tapFix = """
        brew uninstall ffmpeg
        brew tap homebrew-ffmpeg/ffmpeg
        brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-zimg --with-libvmaf
        """

    public var problems: [Problem] {
        var out: [Problem] = []
        if missingTools.contains(.ffmpeg) || missingTools.contains(.ffprobe) {
            out.append(.init(title: "FFmpeg not found",
                             explanation: "ffmpeg and ffprobe do the decoding, filtering and encoding. They were not found in /opt/homebrew/bin, /usr/local/bin or PATH.",
                             fix: "brew install ffmpeg\n\nThen read the zscale note that follows, or set the paths in Settings."))
        }
        if missingTools.contains(.exiftool) {
            out.append(.init(title: "ExifTool not found",
                             explanation: "ExifTool copies the capture date, camera, lens and GPS metadata to the encoded files.",
                             fix: "brew install exiftool"))
        }
        if !missingEncoders.isEmpty {
            out.append(.init(title: "FFmpeg lacks \(missingEncoders.joined(separator: " and "))",
                             explanation: "HEVC encoding needs libx265 and AV1 encoding needs libsvtav1.",
                             fix: Self.tapFix))
        }
        let f = missingFilters
        if f.contains("zscale") {
            out.append(.init(title: "FFmpeg lacks zscale",
                             explanation: "zscale converts full-range camera files (for example Fujifilm 4:2:2 HEVC) to the limited range the encode needs. Homebrew's standard ffmpeg is built without zimg, so full-range clips will fail; limited-range clips still encode.",
                             fix: Self.tapFix))
        }
        if f.contains("libvmaf") {
            out.append(.init(title: "FFmpeg lacks libvmaf",
                             explanation: "The Analysis tab scores test encodes with VMAF. Everything else works without it.",
                             fix: Self.tapFix))
        }
        let rest = f.filter { $0 != "zscale" && $0 != "libvmaf" }
        if !rest.isEmpty {
            out.append(.init(title: "FFmpeg lacks \(rest.joined(separator: ", "))",
                             explanation: "These filters are part of every standard FFmpeg build; this one seems unusual.",
                             fix: "brew install ffmpeg"))
        }
        return out
    }

    /// Names from `ffmpeg -encoders` / `ffmpeg -filters` listings (" V....D libx265  ..." / " TS lut3d  V->V ...").
    public static func parseListing(_ text: String) -> Set<String> {
        var names = Set<String>()
        var pastHeader = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("---") { pastHeader = true; continue }
            guard pastHeader else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { names.insert(String(parts[1])) }
        }
        return names
    }

    public static func check(settings: AppSettings) async -> ToolReport {
        var r = ToolReport()
        let found = ToolLocator.locateAll(settings: settings)
        r.paths = found.paths
        r.missingTools = found.missing
        if let ff = found.paths[.ffmpeg] {
            if let v = try? await ProcessRunner.run(ff, ["-hide_banner", "-version"]) {
                r.ffmpegVersion = v.lines.first
            }
            if let e = try? await ProcessRunner.run(ff, ["-hide_banner", "-encoders"]) { r.encoders = parseListing(e.stdoutText) }
            if let f = try? await ProcessRunner.run(ff, ["-hide_banner", "-filters"]) { r.filters = parseListing(f.stdoutText) }
        }
        return r
    }
}
