// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Persisted settings, with the same JSON keys (and value types) as the Windows version.
/// CRF and max rate are stored as the text typed into their fields, as on Windows.
public struct AppSettings: Equatable, Sendable {
    public var lutPath = ""
    public var lutEnabled = false
    public var codec: Codec = .hevc
    public var autoCrf = false
    public var crfHevc = "21"
    public var crfAv1 = String(CodecArgs.av1Crf(fromHevc: 21))
    public var autoGrain = false
    public var grainLevel: Grain = .off
    /// 0 = off, else VMAF 93/95/97 (v1.1)
    public var qualityTarget = 0
    /// "Later at" time as typed (v1.2); whether a start is scheduled isn't saved
    public var scheduleTime = "04:00"
    /// "Include audio" (v1.3); saved, default on
    public var audioEnabled = true
    /// "Normalise loudness" (v1.3); saved, default off
    public var normalizeAudio = false
    public var vbrEnabled = true
    public var maxRate = "35"
    public var outputMode: OutputMode = .source
    public var outputFolder = ""
    public var subfolder = "From FFmpeg"
    public var csvEnabled = false
    public var csvPath = AppSettings.defaultCsvPath
    // macOS only: tool path overrides (absent = search Homebrew and PATH)
    public var ffmpegPath: String?
    public var ffprobePath: String?
    public var exiftoolPath: String?

    public init() {}

    public static var defaultCsvPath: String {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("ffmpeg_log.csv").path
    }

    public func crf(for codec: Codec) -> String { codec == .av1 ? crfAv1 : crfHevc }
    public mutating func setCrf(_ text: String, for codec: Codec) {
        if codec == .av1 { crfAv1 = text } else { crfHevc = text }
    }
}

extension AppSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case lutPath = "LutPath", lutEnabled = "LutEnabled", codec = "Codec", autoCrf = "AutoCrf", crfHevc = "CrfHevc",
             crfAv1 = "CrfAv1", autoGrain = "AutoGrain", grainLevel = "GrainLevel", qualityTarget = "QualityTarget", scheduleTime = "ScheduleTime", audioEnabled = "AudioEnabled", normalizeAudio = "NormalizeAudio", vbrEnabled = "VbrEnabled",
             maxRate = "MaxRate", outputMode = "OutputMode", outputFolder = "OutputFolder", subfolder = "Subfolder",
             csvEnabled = "CsvEnabled", csvPath = "CsvPath", legacyCrf = "Crf",
             ffmpegPath = "FfmpegPath", ffprobePath = "FfprobePath", exiftoolPath = "ExiftoolPath"
    }

    /// Mirrors `Import-SettingsCore`: a missing flag reads as false, empty CRF/rate keep the default,
    /// a LUT is only restored if the file still exists, and anything unreadable keeps its default.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return String(i) }
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return Fmt.num(d) }
            return nil
        }
        func flag(_ k: CodingKeys) -> Bool {
            if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i != 0 }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return !s.isEmpty }
            return false
        }

        if let lut = str(.lutPath), !lut.isEmpty, FileManager.default.fileExists(atPath: lut) {
            lutPath = lut
            lutEnabled = flag(.lutEnabled)
        }
        autoCrf = flag(.autoCrf)
        if let v = str(.crfHevc), !v.isEmpty { crfHevc = v } else if let v = str(.legacyCrf), !v.isEmpty { crfHevc = v }
        if let v = str(.crfAv1), !v.isEmpty { crfAv1 = v }
        if str(.codec) == "av1" { codec = .av1 }
        autoGrain = flag(.autoGrain)
        if let g = str(.grainLevel).flatMap(Int.init), let grain = Grain(rawValue: g) { grainLevel = grain }
        if let t = str(.qualityTarget).flatMap(Int.init), [93, 95, 97].contains(t) { qualityTarget = t }
        if let t = str(.scheduleTime), !t.isEmpty { scheduleTime = t }
        if c.contains(.audioEnabled) { audioEnabled = flag(.audioEnabled) }   // missing (older files) keeps the default: on
        normalizeAudio = flag(.normalizeAudio)
        vbrEnabled = flag(.vbrEnabled)
        if let v = str(.maxRate), !v.isEmpty { maxRate = v }
        if str(.outputMode) == "custom" { outputMode = .custom }
        if let v = str(.outputFolder) { outputFolder = v }
        if let v = str(.subfolder) { subfolder = v }
        csvEnabled = flag(.csvEnabled)
        if let v = str(.csvPath), !v.isEmpty { csvPath = v }
        ffmpegPath = str(.ffmpegPath).flatMap { $0.isEmpty ? nil : $0 }
        ffprobePath = str(.ffprobePath).flatMap { $0.isEmpty ? nil : $0 }
        exiftoolPath = str(.exiftoolPath).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Same key order and types as `Save-Settings`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lutPath, forKey: .lutPath)
        try c.encode(lutEnabled, forKey: .lutEnabled)
        try c.encode(codec.rawValue, forKey: .codec)
        try c.encode(autoCrf, forKey: .autoCrf)
        try c.encode(crfHevc, forKey: .crfHevc)
        try c.encode(crfAv1, forKey: .crfAv1)
        try c.encode(autoGrain, forKey: .autoGrain)
        try c.encode(grainLevel.rawValue, forKey: .grainLevel)
        try c.encode(qualityTarget, forKey: .qualityTarget)
        try c.encode(scheduleTime.trimmingCharacters(in: .whitespaces), forKey: .scheduleTime)
        try c.encode(audioEnabled, forKey: .audioEnabled)
        try c.encode(normalizeAudio, forKey: .normalizeAudio)
        try c.encode(vbrEnabled, forKey: .vbrEnabled)
        try c.encode(maxRate, forKey: .maxRate)
        try c.encode(outputMode.rawValue, forKey: .outputMode)
        try c.encode(outputFolder.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .outputFolder)
        try c.encode(subfolder, forKey: .subfolder)
        try c.encode(csvEnabled, forKey: .csvEnabled)
        try c.encode(csvPath, forKey: .csvPath)
        try c.encodeIfPresent(ffmpegPath, forKey: .ffmpegPath)
        try c.encodeIfPresent(ffprobePath, forKey: .ffprobePath)
        try c.encodeIfPresent(exiftoolPath, forKey: .exiftoolPath)
    }
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL) { self.url = url }

    /// `IVE_SETTINGS_PATH` redirects the file (tests and automation never touch the real settings).
    public static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["IVE_SETTINGS_PATH"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Ideal Video Encoder/settings.json")
    }

    /// Defaults when there is no file; throws only when a file exists but can't be parsed.
    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        var data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }   // PowerShell writes a BOM
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(settings).write(to: url, options: .atomic)
    }
}
