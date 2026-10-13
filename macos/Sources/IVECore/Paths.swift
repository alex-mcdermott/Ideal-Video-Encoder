// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Trim {
    public enum Value: Equatable, Sendable {
        case empty
        case seconds(Double)
        case invalid
    }

    /// `ConvertTo-Seconds`: "90", "1:30" or "00:01:30.5" -> seconds; empty -> .empty.
    public static func parse(_ text: String) -> Value {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 3 { return .invalid }
        var total = 0.0
        for p in parts {
            guard let v = parseFloat(String(p)), v >= 0 else { return .invalid }
            total = total * 60 + v
        }
        return .seconds(total)
    }

    /// .NET `NumberStyles.Float` with the invariant culture (no hex, no "inf"/"nan").
    static func parseFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(t)
    }
}

public enum OutputMode: String, Codable, Sendable { case source, custom }

public enum OutputPaths {
    /// `Resolve-OutputDir`: the source folder or the custom folder, plus the optional subfolder.
    public static func directory(for file: String, mode: OutputMode, folder: String, subfolder: String) -> String {
        let base = (mode == .custom && !folder.isEmpty) ? folder : (file as NSString).deletingLastPathComponent
        let sub = cleanSubfolder(subfolder)
        return sub.isEmpty ? base : (base as NSString).appendingPathComponent(sub)
    }

    public static func cleanSubfolder(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Returns an error message, or nil when the subfolder is usable (empty means none).
    public static func validateSubfolder(_ s: String) -> String? {
        let sub = cleanSubfolder(s)
        if sub.isEmpty { return nil }
        for seg in sub.split(separator: "/", omittingEmptySubsequences: false) {
            // ":" shows up as "/" in Finder, so a name containing it would not look like what was typed
            if seg.isEmpty || seg == ".." || seg == "." || seg.contains(":") || seg.contains("\0") {
                return "Subfolder '\(sub)' is not a valid folder name."
            }
        }
        return nil
    }

    public static func validateCustomFolder(_ s: String) -> String? {
        let f = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return "Choose an output folder." }
        if !f.hasPrefix("/") || f.contains("\0") { return "The output folder must be a full path, e.g. /Volumes/Exports." }
        return nil
    }

    /// The "Saves to" line.
    public static func preview(sample: String?, mode: OutputMode, folder: String, subfolder: String, ext: String) -> String {
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .custom && folder.isEmpty { return "Choose an output folder." }
        if let sample {
            let dir = directory(for: sample, mode: mode, folder: folder, subfolder: subfolder)
            let base = ((sample as NSString).lastPathComponent as NSString).deletingPathExtension
            return (dir as NSString).appendingPathComponent(base + ext)
        }
        let root = mode == .custom ? folder : "<clip folder>"
        let sub = cleanSubfolder(subfolder)
        return sub.isEmpty ? "\(root)/<clip>\(ext)" : "\(root)/\(sub)/<clip>\(ext)"
    }
}

/// Picks output names for one run: never the source itself, never a name already used in this run.
public struct OutputNamer: Sendable {
    private var used = Set<String>()
    public init() {}

    public mutating func next(source: String, directory: String, ext: String) -> String {
        let base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let src = (source as NSString).standardizingPath.lowercased()
        var n = 1
        var out = (directory as NSString).appendingPathComponent(base + ext)
        while (out as NSString).standardizingPath.lowercased() == src || used.contains(out.lowercased()) {
            n += 1
            out = (directory as NSString).appendingPathComponent("\(base)_\(n)\(ext)")
        }
        used.insert(out.lowercased())
        return out
    }
}
