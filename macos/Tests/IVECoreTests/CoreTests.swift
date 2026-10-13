// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import IVECore

@Suite struct FormattingTests {
    @Test func dotNetNumbers() {
        #expect(Fmt.num(35) == "35")
        #expect(Fmt.num(70) == "70")
        #expect(Fmt.num(12.5) == "12.5")
        #expect(Fmt.num(0.0738) == "0.0738")
        #expect(Fmt.num(88000000) == "88000000")
        #expect(Fmt.num(-86.1) == "-86.1")
    }
    @Test func custom() {
        #expect(Fmt.signed1(0) == "0.0")
        #expect(Fmt.signed1(0.5) == "+0.5")
        #expect(Fmt.signed1(-1.3) == "-1.3")
        #expect(Fmt.upTo1(52.0) == "52")
        #expect(Fmt.upTo1(359.31) == "359.3")
        #expect(Fmt.clock(3725) == "01:02:05")
        #expect(Fmt.duration(30.03) == "0:30")
        #expect(Fmt.duration(3725) == "1:02:05")
        #expect(Fmt.size(314_572_800) == "300 MB")
        #expect(Fmt.size(1_717_986_918) == "1.60 GB")
    }
}

@Suite struct TrimTests {
    @Test(arguments: [("90", 90.0), ("1:30", 90), ("00:01:30.5", 90.5), (" 2.25 ", 2.25), ("1e2", 100), ("0", 0), ("1:00:00", 3600), (".5", 0.5)])
    func valid(text: String, seconds: Double) { #expect(Trim.parse(text) == .seconds(seconds)) }

    @Test(arguments: ["1:2:3:4", "-5", "abc", "1:", "1,5", "inf", "0x10", "1:-2", "nan"])
    func invalid(text: String) { #expect(Trim.parse(text) == .invalid) }

    @Test func empty() {
        #expect(Trim.parse("") == .empty)
        #expect(Trim.parse("   ") == .empty)
    }
}

@Suite struct OutputTests {
    @Test func directories() {
        #expect(OutputPaths.directory(for: "/v/a.MOV", mode: .source, folder: "/out", subfolder: "From FFmpeg") == "/v/From FFmpeg")
        #expect(OutputPaths.directory(for: "/v/a.MOV", mode: .custom, folder: "/out", subfolder: " /sub/ ") == "/out/sub")
        #expect(OutputPaths.directory(for: "/v/a.MOV", mode: .custom, folder: "", subfolder: "") == "/v")
        #expect(OutputPaths.directory(for: "/v/a.MOV", mode: .custom, folder: "/out", subfolder: "a/b") == "/out/a/b")
    }

    @Test func neverOverwriteSource() {
        var n = OutputNamer()
        // HEVC output next to a .mov source with no subfolder lands on the source's own name
        #expect(n.next(source: "/v/clip.mov", directory: "/v", ext: ".MOV") == "/v/clip_2.MOV")
    }

    @Test func collisionsWithinRun() {
        var n = OutputNamer()
        #expect(n.next(source: "/card1/DSCF0001.MOV", directory: "/out", ext: ".MOV") == "/out/DSCF0001.MOV")
        #expect(n.next(source: "/card2/DSCF0001.MOV", directory: "/out", ext: ".MOV") == "/out/DSCF0001_2.MOV")
        #expect(n.next(source: "/card3/dscf0001.mov", directory: "/out", ext: ".MOV") == "/out/dscf0001_3.MOV")
        #expect(n.next(source: "/card1/DSCF0002.MOV", directory: "/out", ext: ".MOV") == "/out/DSCF0002.MOV")
    }

    @Test func subfolderValidation() {
        #expect(OutputPaths.validateSubfolder("From FFmpeg") == nil)
        #expect(OutputPaths.validateSubfolder("") == nil)
        #expect(OutputPaths.validateSubfolder("  ") == nil)
        #expect(OutputPaths.validateSubfolder("a/b") == nil)
        #expect(OutputPaths.validateSubfolder("/a/") == nil)
        #expect(OutputPaths.validateSubfolder("a//b") != nil)
        #expect(OutputPaths.validateSubfolder("../up") != nil)
        #expect(OutputPaths.validateSubfolder("a:b") == "Subfolder 'a:b' is not a valid folder name.")
        #expect(OutputPaths.validateCustomFolder("") == "Choose an output folder.")
        #expect(OutputPaths.validateCustomFolder("relative/path") != nil)
        #expect(OutputPaths.validateCustomFolder("/Volumes/Exports") == nil)
    }

    @Test func savesToPreview() {
        #expect(OutputPaths.preview(sample: "/v/a.MOV", mode: .source, folder: "", subfolder: "From FFmpeg", ext: ".MP4") == "/v/From FFmpeg/a.MP4")
        #expect(OutputPaths.preview(sample: nil, mode: .source, folder: "", subfolder: "From FFmpeg", ext: ".MOV") == "<clip folder>/From FFmpeg/<clip>.MOV")
        #expect(OutputPaths.preview(sample: nil, mode: .custom, folder: "/o", subfolder: "", ext: ".MOV") == "/o/<clip>.MOV")
        #expect(OutputPaths.preview(sample: "/v/a.MOV", mode: .custom, folder: " ", subfolder: "", ext: ".MOV") == "Choose an output folder.")
    }
}

@Suite struct SettingsTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ive-settings-\(UUID().uuidString)/settings.json")
    }

    @Test func defaults() {
        let s = AppSettings()
        #expect(s.codec == .hevc && s.crfHevc == "21" && s.crfAv1 == "28" && s.grainLevel == .off)
        #expect(s.vbrEnabled && s.maxRate == "35" && s.subfolder == "From FFmpeg" && s.outputMode == .source)
        #expect(!s.autoCrf && !s.autoGrain && !s.lutEnabled && !s.csvEnabled)
        #expect(s.csvPath.hasSuffix("/Desktop/ffmpeg_log.csv"))
    }

    @Test func missingFileGivesDefaults() throws {
        #expect(try SettingsStore(url: tempURL()).load() == AppSettings())
    }

    @Test func roundTrip() throws {
        let lut = FileManager.default.temporaryDirectory.appendingPathComponent("ive-\(UUID().uuidString).cube")
        try "LUT_3D_SIZE 2\n".write(to: lut, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lut) }
        var s = AppSettings()
        s.codec = .av1; s.crfHevc = "19"; s.crfAv1 = "30"; s.autoCrf = true; s.grainLevel = .strong; s.autoGrain = true
        s.vbrEnabled = false; s.maxRate = "60"; s.lutPath = lut.path; s.lutEnabled = true; s.outputMode = .custom
        s.outputFolder = "/Volumes/Out"; s.subfolder = ""; s.csvEnabled = true; s.csvPath = "/tmp/log.csv"; s.ffmpegPath = "/opt/x/ffmpeg"
        s.qualityTarget = 97; s.scheduleTime = "4:30 pm"
        let store = SettingsStore(url: tempURL())
        try store.save(s)
        #expect(try store.load() == s)

        // Same keys and value types as Save-Settings
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        #expect(Set(obj.keys) == ["Codec", "CrfHevc", "CrfAv1", "AutoCrf", "GrainLevel", "AutoGrain", "VbrEnabled", "MaxRate", "LutPath",
                                  "LutEnabled", "OutputMode", "OutputFolder", "Subfolder", "CsvEnabled", "CsvPath", "FfmpegPath",
                                  "QualityTarget", "ScheduleTime"])
        #expect(obj["QualityTarget"] as? Int == 97)
        #expect(obj["ScheduleTime"] as? String == "4:30 pm")
        #expect(obj["CrfHevc"] as? String == "19")
        #expect(obj["MaxRate"] as? String == "60")
        #expect(obj["GrainLevel"] as? Int == 2)
        #expect(obj["Codec"] as? String == "av1")
        #expect(obj["OutputMode"] as? String == "custom")
    }

    @Test func readsWindowsFile() throws {
        // As written by Windows PowerShell 5.1 ConvertTo-Json + Set-Content -Encoding UTF8 (BOM)
        let json = """
            {
                "LutPath":  "C:\\\\LUTs\\\\missing.cube",
                "LutEnabled":  true,
                "Codec":  "av1",
                "AutoCrf":  false,
                "CrfHevc":  "20",
                "CrfAv1":  "27",
                "AutoGrain":  true,
                "GrainLevel":  1,
                "VbrEnabled":  true,
                "MaxRate":  "60",
                "OutputMode":  "custom",
                "OutputFolder":  "D:\\\\Exports",
                "Subfolder":  "",
                "CsvEnabled":  true,
                "CsvPath":  "C:\\\\Users\\\\me\\\\Desktop\\\\ffmpeg_log.csv",
                "QualityTarget":  93,
                "ScheduleTime":  "19:15"
            }
            """
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8)).write(to: url)
        let s = try SettingsStore(url: url).load()
        #expect(s.codec == .av1 && s.crfHevc == "20" && s.crfAv1 == "27" && s.grainLevel == .light && s.autoGrain)
        #expect(s.maxRate == "60" && s.outputMode == .custom && s.subfolder == "" && s.csvEnabled)
        #expect(s.qualityTarget == 93 && s.scheduleTime == "19:15")
        // LUT that doesn't exist here is dropped, and Apply LUT stays off
        #expect(s.lutPath == "" && !s.lutEnabled)
    }

    @Test func lenientTypesAndMissingKeys() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"Crf": 18, "MaxRate": 45, "GrainLevel": 7, "Subfolder": "Out"}"#.utf8).write(to: url)
        let s = try SettingsStore(url: url).load()
        #expect(s.crfHevc == "18")          // legacy key
        #expect(s.maxRate == "45")          // number accepted
        #expect(s.grainLevel == .off)       // out of range ignored
        #expect(!s.vbrEnabled)              // missing flag reads as false, as [bool]$null does
        #expect(s.subfolder == "Out")
        #expect(s.qualityTarget == 0 && s.scheduleTime == "04:00")   // v1.0 files: defaults
    }
}

@Suite struct RunOptionsTests {
    @Test func validDefaults() throws {
        let o = try RunOptions.validate(settings: AppSettings(), exposure: 0.04, trimStart: "", trimEnd: "1:30")
        #expect(o.crf == 21 && o.cap == 35 && o.exposure == 0 && o.trimEnd == 90 && o.trimStart == nil && o.subfolder == "From FFmpeg")
        #expect(o.vbvText == "35M" && o.exposureText == "0.0")
    }

    func message(_ s: AppSettings, ev: Double = 0, start: String = "", end: String = "") -> String? {
        do { _ = try RunOptions.validate(settings: s, exposure: ev, trimStart: start, trimEnd: end); return nil }
        catch { return (error as? ProcessError)?.message }
    }

    @Test func messages() {
        var s = AppSettings()
        s.crfHevc = "52"
        #expect(message(s) == "CRF must be a whole number from 0 to 51 for HEVC.")
        s.codec = .av1; s.crfAv1 = "x"
        #expect(message(s) == "CRF must be a whole number from 0 to 63 for AV1.")
        s.autoCrf = true
        #expect(message(s) == nil)
        s = AppSettings(); s.maxRate = "0"
        #expect(message(s) == "Max rate must be a positive number of Mbps.")
        s.vbrEnabled = false
        #expect(message(s) == nil)
        s = AppSettings(); s.lutEnabled = true; s.lutPath = "/nonexistent.cube"
        #expect(message(s) == "Choose a LUT file, or turn off Apply LUT.")
        #expect(message(AppSettings(), start: "abc") == "Trim times must be seconds (90) or mm:ss (1:30).")
        #expect(message(AppSettings(), start: "10", end: "5") == "Trim end must be after the start.")
        s = AppSettings(); s.outputMode = .custom
        #expect(message(s) == "Choose an output folder.")
        s.outputFolder = "Exports"
        #expect(message(s) == "The output folder must be a full path, e.g. /Volumes/Exports.")
        s = AppSettings(); s.subfolder = "../x"
        #expect(message(s) == "Subfolder '../x' is not a valid folder name.")
    }

    @Test func autoCrfFallback() throws {
        var s = AppSettings(); s.autoCrf = true; s.crfHevc = ""
        #expect(try RunOptions.validate(settings: s, exposure: 0, trimStart: "", trimEnd: "").crf == 21)
        s.codec = .av1; s.crfAv1 = "99"
        #expect(try RunOptions.validate(settings: s, exposure: 0, trimStart: "", trimEnd: "").crf == 28)
    }
}

@Suite struct AutoRuleTests {
    func sig(psnr: Double? = nil, motion: Double? = nil) -> ClipSignals {
        var s = ClipSignals(); s.noisePSNR = psnr; s.motion = motion; return s
    }

    @Test func crf() {
        #expect(AutoRules.crf(manual: 30, auto: false, codec: .hevc, isFLog2: true, iso: 6400, signals: sig()) == 30)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: 400, signals: sig()) == 22)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: true, iso: nil, signals: sig()) == 20)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: 3200, signals: sig()) == 20)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: true, iso: nil, signals: sig(psnr: 41)) == 22)  // PSNR wins over F-Log2
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: nil, signals: sig(psnr: 34, motion: 60)) == 18)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: nil, signals: sig(psnr: 37.9)) == 20)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: nil, signals: sig(psnr: 39)) == 21)
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .hevc, isFLog2: false, iso: nil, signals: sig(motion: 5)) == 22)  // no detail value
        #expect(AutoRules.crf(manual: 0, auto: true, codec: .av1, isFLog2: false, iso: nil, signals: sig(psnr: 34, motion: 60)) == 25)
    }

    @Test func grain() {
        #expect(AutoRules.grain(manual: .light, auto: false, isFLog2: true, iso: 6400, psnr: 30) == .light)
        #expect(AutoRules.grain(manual: .light, auto: true, isFLog2: false, iso: 400, psnr: nil) == .off)
        #expect(AutoRules.grain(manual: .off, auto: true, isFLog2: false, iso: 3200, psnr: nil) == .strong)
        #expect(AutoRules.grain(manual: .off, auto: true, isFLog2: false, iso: 400, psnr: 36) == .light)
        #expect(AutoRules.grain(manual: .off, auto: true, isFLog2: false, iso: 400, psnr: 34) == .strong)
        #expect(AutoRules.grain(manual: .off, auto: true, isFLog2: false, iso: 400, psnr: 40) == .off)
        #expect(AutoRules.analysisGrain(manual: .off, auto: true, isFLog2: true, iso: nil) == .strong)
    }

    @Test func parseSignals() {
        var acc = ClipAnalysis.StatsAccumulator()
        for l in ["[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YMIN=20", "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YMAX=230",
                  "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YDIF=2", "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.SATAVG=40.5",
                  "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YMIN=16", "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YDIF=4",
                  "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YMAX=235", "[Parsed_metadata_3 @ 0x6000] lavfi.signalstats.YAVG=100"] {
            acc.add(l)
        }
        #expect(acc.motion == 3 && acc.colour == 40.5 && acc.brightMin == 16 && acc.brightMax == 235)
        #expect(ClipAnalysis.psnr(from: "[Parsed_psnr_4 @ 0x60] PSNR y:40.10 u:45.20 v:46.00 average:41.234567 min:39.10 max:43.20") == 41.234567)
        #expect(ClipAnalysis.psnr(from: "frame=  10 fps=0.0 q=-0.0 size=N/A time=00:00:00.33") == nil)
    }
}

@Suite struct MetadataTests {
    @Test func parse() {
        #expect(Metadata.parseISO(["ISO                             : 400"]) == 400)
        #expect(Metadata.parseISO([]) == nil)
        #expect(Metadata.isFLog2(["User Comment                    : F-Log2"]))
        #expect(!Metadata.isFLog2(["User Comment                    : "]))
        let t = Metadata.chooseTimestamp(["[ExifIFD]       DateTimeOriginal                : 2026:10:09 13:08:21",
                                          "[XMP-exif]      DateTimeOriginal                : 2020:01:01 00:00:00"])
        #expect(t?.value == "2026:10:09 13:08:21")
        #expect(Metadata.chooseTimestamp(["[ExifIFD]       ISO : 400"]) == nil)
    }

    @Test func exifArguments() throws {
        let a = Metadata.copyArguments(source: "/s.MOV", output: "/o.MOV")
        // Golden: the $exifArgs1 list in the Windows script, item by item ($file -> source)
        let ps1 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Ideal-Video-Encoder.ps1")
        let script = try String(contentsOf: ps1, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let block = script.components(separatedBy: "$exifArgs1 = @(")[1].components(separatedBy: "\n            )")[0]
        var expected: [String] = []
        for line in block.split(separator: "\n") {
            let code = line.components(separatedBy: "#")[0]
            for item in code.split(separator: ",") {
                let t = item.trimmingCharacters(in: .whitespaces)
                if t == "$file" { expected.append("/s.MOV") }
                else if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { expected.append(String(t.dropFirst().dropLast())) }
            }
        }
        #expect(expected.count == 42)
        #expect(a == expected + ["/o.MOV"])
        #expect(Array(a.prefix(8)) == ["-api", "QuickTimeUTC=1", "-TagsFromFile", "/s.MOV", "-All", "-makernotes", "-make", "-model"])
        #expect(Array(a.suffix(2)) == ["-overwrite_original", "/o.MOV"])
        #expect(a.contains("-VideoKeys:LensModel-eng-GB<LensInfo") && a.contains("-Keys:GPSCoordinates<Composite:GPSPosition"))
        #expect(Metadata.fileDateArguments(timestamp: "2026:10:09 13:08:21", output: "/o.MOV") ==
                ["-FileCreateDate=2026:10:09 13:08:21", "-FileModifyDate=2026:10:09 13:08:21", "-overwrite_original", "/o.MOV"])
    }

    @Test func csv() {
        let notes = CsvLog.notes(codec: .hevc, iso: 400, isFLog2: false, isFullRange: false, exposureText: "0.0", vbvText: "35M")
        #expect(notes == "Codec=HEVC ISO=400 FLog2=False Range=video EV=0.0 VBV=35M")
        let row = CsvLog.row(name: "CLIP0001.MOV", iso: 400, isFLog2: false, crf: 21, grain: .off, origBitrate: 88000000,
                             origSizeMB: 359.3104, newSizeMB: 50.1249, ratio: 86.1, heat: "[6]", notes: notes)
        #expect(row == #""CLIP0001.MOV",400,False,21,0,88000000,359.31,50.12,86.1,[6],"Codec=HEVC ISO=400 FLog2=False Range=video EV=0.0 VBV=35M""#)
        let none = CsvLog.row(name: "a.mov", iso: nil, isFLog2: true, crf: 28, grain: .strong, origBitrate: nil,
                              origSizeMB: 10, newSizeMB: 12, ratio: -20, heat: "[1]", notes: "n")
        #expect(none == #""a.mov",,True,28,2,,10,12,-20,[1],"n""#)
    }
}

@Suite struct ProbeAndToolTests {
    @Test func parseProbe() throws {
        let json = #"{"programs":[],"streams":[{"width":6240,"height":4160,"pix_fmt":"yuv422p10le","color_range":"pc","avg_frame_rate":"30000/1001","bit_rate":"94933202"}],"format":{"duration":"4.004000","bit_rate":"95000000"}}"#
        let m = try Probe.parse(Data(json.utf8))
        #expect(m.width == 6240 && m.height == 4160 && m.isFullRange && m.duration == 4.004 && m.streamBitRate == 94933202)
        #expect(abs((m.frameRate ?? 0) - 29.97) < 0.01)
        #expect(Heat.bar(m.complexity) == "[6]")
        let noRange = try Probe.parse(Data(#"{"streams":[{"width":10,"height":10}],"format":{}}"#.utf8))
        #expect(!noRange.isFullRange && noRange.streamBitRate == nil && noRange.duration == 0)
    }

    @Test func listings() {
        let filters = """
            Filters:
              T.. = Timeline support
              ------
             TS lut3d             V->V       Adjust colors using a 3D LUT.
             .. libvmaf           VV->V      Calculate the VMAF between two video streams.
            """
        #expect(ToolReport.parseListing(filters) == ["lut3d", "libvmaf"])
        var r = ToolReport()
        r.paths = [.ffmpeg: "/x", .ffprobe: "/y", .exiftool: "/z"]
        r.encoders = ["libx265", "libsvtav1"]
        r.filters = ["lut3d", "lutyuv", "libvmaf", "signalstats", "hqdn3d", "psnr"]
        #expect(r.missingFilters == ["zscale"])
        #expect(r.problems.map(\.title) == ["FFmpeg lacks zscale"])
        #expect(r.problems[0].fix.contains("--with-zimg"))
    }

    @Test func locatorOverride() {
        #expect(ToolLocator.locate(.ffmpeg, override: "/nonexistent/ffmpeg") == nil)
        #expect(ToolLocator.locate(.ffmpeg, override: "/bin/ls") == "/bin/ls")
        #expect(ToolLocator.locate(.ffmpeg, override: nil, path: "") == nil ||
                ToolLocator.searchDirectories.contains { ToolLocator.locate(.ffmpeg, path: "")!.hasPrefix($0) })
    }
}

@Suite struct ScheduleTests {
    var london: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test(arguments: [("04:30", 4, 30), ("4:30", 4, 30), ("4.30", 4, 30), ("0430", 4, 30), ("430", 4, 30), ("16:45", 16, 45),
                      ("4:30 pm", 16, 30), ("4pm", 16, 0), ("4 PM", 16, 0), ("12am", 0, 0), ("12pm", 12, 0), ("12:15a", 0, 15), (" 7 ", 7, 0), ("0", 0, 0)])
    func parses(text: String, h: Int, m: Int) { #expect(Schedule.parse(text) == .init(hour: h, minute: m)) }

    @Test(arguments: ["", "24:00", "13pm", "0am", "4:60", "four", "4:3", "12345", "4:30:00", "-1"])
    func rejects(text: String) { #expect(Schedule.parse(text) == nil) }

    @Test func nextOccurrence() {
        let c = london
        let now = date(2026, 3, 1, 14, 30, c)
        #expect(Schedule.nextStart(.init(hour: 19, minute: 0), after: now, calendar: c) == date(2026, 3, 1, 19, 0, c))
        #expect(Schedule.nextStart(.init(hour: 4, minute: 0), after: now, calendar: c) == date(2026, 3, 2, 4, 0, c))
        #expect(Schedule.nextStart(.init(hour: 14, minute: 30), after: now, calendar: c) == date(2026, 3, 2, 14, 30, c))
    }

    @Test func daylightSaving() {
        let c = london
        let utc = TimeZone(identifier: "UTC")!
        // Spring forward (29 Mar 2026, 01:00 GMT -> 02:00 BST): 01:30 doesn't exist, start just after the gap at 02:30 BST
        let spring = Schedule.nextStart(.init(hour: 1, minute: 30), after: date(2026, 3, 28, 22, 0, c), calendar: c)
        #expect(spring == Date(timeIntervalSince1970: 1_774_747_800))   // 2026-03-29 01:30 UTC = 02:30 BST
        // Fall back (25 Oct 2026, 02:00 BST -> 01:00 GMT): 01:30 happens twice; use the second (GMT) one
        let fall = Schedule.nextStart(.init(hour: 1, minute: 30), after: date(2026, 10, 24, 22, 0, c), calendar: c)
        var u = Calendar(identifier: .gregorian); u.timeZone = utc
        #expect(u.dateComponents([.day, .hour, .minute], from: fall) == DateComponents(day: 25, hour: 1, minute: 30))
        // Countdown across the change is real elapsed time: 22:00 BST to 04:00 GMT is 7 hours
        let at = Schedule.nextStart(.init(hour: 4, minute: 0), after: date(2026, 10, 24, 22, 0, c), calendar: c)
        #expect(Schedule.countdown(at.timeIntervalSince(date(2026, 10, 24, 22, 0, c))) == "7:00:00")
    }

    @Test func hintText() {
        let c = london
        let now = date(2026, 7, 6, 23, 0, c)
        let h = Schedule.hint(for: "4:30", now: now, calendar: c, locale: Locale(identifier: "en_GB"))
        #expect(h == "Starts Tue 04:30 British Summer Time, in 5 h 30 min")
        #expect(Schedule.hint(for: "23:30", now: now, calendar: c, locale: Locale(identifier: "en_GB")).hasSuffix("in 30 min"))
        #expect(Schedule.hint(for: "nonsense", now: now, calendar: c) == "Enter a time, e.g. 04:30 or 4:30 pm.")
        #expect(Schedule.countdown(3725) == "1:02:05" && Schedule.countdown(90000) == "25:00:00")
    }
}
