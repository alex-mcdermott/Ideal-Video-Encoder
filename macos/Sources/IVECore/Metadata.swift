// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// ExifTool steps, copied from the Windows worker.
public enum Metadata {
    public static func isoArguments(_ path: String) -> [String] { ["-ISO", path] }
    public static func userCommentArguments(_ path: String) -> [String] { ["-UserComment", path] }

    /// `Get-ISO`: "ISO                             : 400" -> 400.
    public static func parseISO(_ lines: [String]) -> Int? {
        guard let line = lines.first(where: { $0.contains("ISO") }) else { return nil }
        let parts = line.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// `Is-FLog2`.
    public static func isFLog2(_ lines: [String]) -> Bool { lines.contains { $0.contains("F-Log2") } }

    public static func timestampArguments(_ path: String) -> [String] {
        ["-s", "-G1", "-api", "QuickTimeUTC=1", "-UserData:DateTimeOriginal", "-EXIF:DateTimeOriginal", "-XMP:DateTimeOriginal", path]
    }

    /// First non-empty DateTimeOriginal value, and the line it came from.
    public static func chooseTimestamp(_ lines: [String]) -> (value: String, line: String)? {
        for l in lines {
            guard let r = l.range(of: "DateTimeOriginal\\s*:\\s*(.+)$", options: .regularExpression) else { continue }
            let m = l[r]
            guard let colon = m.firstIndex(of: ":") else { continue }
            let v = m[m.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return (v, l) }
        }
        return nil
    }

    /// Pass 1: copy core metadata, with Apple-compatible keys (followed by the output path).
    public static func copyArguments(source: String, output: String) -> [String] {
        [
            "-api", "QuickTimeUTC=1",
            "-TagsFromFile", source,
            "-All", "-makernotes", "-make", "-model",

            // Core Make/Model
            "-Keys:Make<Make",
            "-Keys:Model<Model",
            "-QuickTime:Make<Make",
            "-QuickTime:Model<Model",

            // Standard lens data
            "-LensModel<LensModel",
            "-LensModel<LensInfo",         // fallback for Fujifilm
            "-LensModel<Lens",             // fallback for Canon
            "-FocalLength<FocalLength",
            "-FocalLengthIn35mmFormat<FocalLengthIn35mmFormat",

            // Apple VideoKeys (Apple Photos / iPhone)
            "-VideoKeys:LensModel-eng-GB<LensInfo",
            "-VideoKeys:FocalLengthIn35mmFormat-eng-GB<FocalLengthIn35mmFormat",
            "-VideoKeys:LensModel<LensModel",
            "-VideoKeys:LensModel<LensInfo",
            "-VideoKeys:FocalLengthIn35mmFormat<FocalLengthIn35mmFormat",
            "-VideoKeys:CameraFocalLength35mmEquivalent<FocalLengthIn35mmFormat",

            // Fujifilm film simulations and colour
            "-Keys:FilmSimulation<FilmMode",
            "-Keys:DynamicRange<DynamicRangeSetting",
            "-Keys:WhiteBalance<WhiteBalance",
            "-Keys:HighlightTone<HighlightTone",
            "-Keys:ShadowTone<ShadowTone",

            // Focus and hardware
            "-Keys:FocusMode<FocusMode",
            "-Keys:ImageStabilization<ImageStabilization",
            "-Keys:CameraSerialNumber<InternalSerialNumber",
            "-Keys:LensSerialNumber<LensSerialNumber",

            // Extended GPS
            "-GPSAltitude<GPSAltitude",
            "-GPSAltitudeRef<GPSAltitudeRef",
            "-GPSSpeed<GPSSpeed",
            "-GPSSpeedRef<GPSSpeedRef",

            // Time and location
            "-Keys:GPSCoordinates<Composite:GPSPosition",
            "-Keys:CreationDate<XMP:DateTimeOriginal",
            "-Keys:CreationDate<EXIF:DateTimeOriginal",
            "-QuickTime:CreateDate<DateTimeOriginal",
            "-QuickTime:ModifyDate<DateTimeOriginal",

            "-overwrite_original",
            output,
        ]
    }

    /// Pass 2: file-system dates from the capture time (FileCreateDate is supported by ExifTool on macOS).
    public static func fileDateArguments(timestamp: String, output: String) -> [String] {
        ["-FileCreateDate=\(timestamp)", "-FileModifyDate=\(timestamp)", "-overwrite_original", output]
    }
}

/// CSV log, same header and row format as the Windows version (UTF-8 with BOM, CRLF).
public enum CsvLog {
    public static let header = "File,ISO,FLog2,CRF,Grain,OrigBitrate(bps),OrigSize(MB),NewSize(MB),Compression(%),Heat,Notes"

    public static func notes(codec: Codec, iso: Int?, isFLog2: Bool, isFullRange: Bool, exposureText: String, vbvText: String) -> String {
        "Codec=\(codec.displayName) ISO=\(iso.map(String.init) ?? "") FLog2=\(isFLog2 ? "True" : "False") Range=\(isFullRange ? "full" : "video") EV=\(exposureText) VBV=\(vbvText)"
    }

    public static func row(name: String, iso: Int?, isFLog2: Bool, crf: Int, grain: Grain, origBitrate: Double?,
                           origSizeMB: Double, newSizeMB: Double, ratio: Double, heat: String, notes: String) -> String {
        let fields = [
            "\"\(name)\"", iso.map(String.init) ?? "", isFLog2 ? "True" : "False", "\(crf)", "\(grain.rawValue)",
            origBitrate.map(Fmt.num) ?? "", Fmt.num(Fmt.round(origSizeMB, 2)), Fmt.num(Fmt.round(newSizeMB, 2)),
            Fmt.num(ratio), heat, "\"\(notes)\"",
        ]
        return fields.joined(separator: ",")
    }

    public static func createIfNeeded(_ path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((header + "\r\n").utf8))
        try data.write(to: URL(fileURLWithPath: path))
    }

    public static func append(_ line: String, to path: String) throws {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data((line + "\r\n").utf8))
    }
}
