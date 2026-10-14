// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the worker needs to know about a source clip (one ffprobe call instead of the script's several).
public struct MediaInfo: Sendable, Equatable {
    public var width = 0
    public var height = 0
    public var pixelFormat: String?
    public var colorRange: String?
    public var streamBitRate: Double?
    public var formatBitRate: Double?
    public var duration: Double = 0
    public var frameRate: Double?
    public var hasVideo = false

    public init() {}

    /// `Get-VideoRangeFull`: "pc"/"full" is full range; anything else (including unknown) is treated as limited.
    public var isFullRange: Bool {
        guard let r = colorRange?.lowercased() else { return false }
        return r == "pc" || r == "full"
    }

    /// `Complexity-Score`: stream bit rate / duration, a rough proxy for content complexity.
    public var complexity: Double {
        guard duration > 0 else { return 0 }
        return (streamBitRate ?? 0) / duration
    }
}

public enum Probe {
    public static func arguments(for path: String) -> [String] {
        ["-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,pix_fmt,color_range,bit_rate,avg_frame_rate:format=duration,bit_rate",
         "-of", "json", path]
    }

    public static func parse(_ data: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessError("ffprobe returned unexpected output")
        }
        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        var m = MediaInfo()
        if let s = (root["streams"] as? [[String: Any]])?.first {
            m.hasVideo = true
            m.width = s["width"] as? Int ?? 0
            m.height = s["height"] as? Int ?? 0
            m.pixelFormat = s["pix_fmt"] as? String
            m.colorRange = s["color_range"] as? String
            m.streamBitRate = num(s["bit_rate"])
            if let r = s["avg_frame_rate"] as? String {
                let p = r.split(separator: "/").compactMap { Double($0) }
                if p.count == 2, p[1] > 0, p[0] > 0 { m.frameRate = p[0] / p[1] }
            }
        }
        if let f = root["format"] as? [String: Any] {
            m.duration = num(f["duration"]) ?? 0
            m.formatBitRate = num(f["bit_rate"])
        }
        return m
    }

    public static func run(ffprobe: String, path: String) async throws -> MediaInfo {
        let r = try await ProcessRunner.run(ffprobe, arguments(for: path))
        guard r.exitCode == 0 else {
            let msg = r.stderrText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(r.exitCode)"
            throw ProcessError("ffprobe could not read the file: \(msg)")
        }
        return try parse(r.stdout)
    }
}

/// `Heat-Bar`: complexity bucket for the CSV/log.
public enum Heat {
    public static func bar(_ x: Double) -> String {
        if x <= 800_000 { return "[1]" }
        if x <= 1_600_000 { return "[2]" }
        if x <= 2_400_000 { return "[3]" }
        if x <= 3_200_000 { return "[4]" }
        if x <= 4_800_000 { return "[5]" }
        return "[6]"
    }
}
