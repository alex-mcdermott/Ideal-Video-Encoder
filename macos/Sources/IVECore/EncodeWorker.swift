// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Status keys, as in the Windows queue (they drive badge colours).
public enum ItemState: String, Sendable {
    case queued, waiting, active, done, error, cancelled
}

/// Messages from a worker to the UI (the script's `$Sync.Queue` messages).
public enum WorkerEvent: Sendable, Equatable {
    case log(String)
    case item(path: String, status: String, state: ItemState, progress: Double?, detail: String?)
    case overall(percent: Double, text: String, eta: String)
    case finished(ok: Int, failed: Int, cancelled: Bool, elapsed: TimeInterval)
}

public typealias WorkerSink = @Sendable (WorkerEvent) -> Void

/// Runs short helper tools to completion even if the run is cancelled meanwhile
/// (on Windows, Cancel only kills ffmpeg, never ffprobe or ExifTool).
func uncancellable<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: body).value
}

/// Port of `$WorkerScript`: encodes each clip in turn. Cancel the surrounding Task to stop;
/// the running ffmpeg is killed and its partial output deleted.
public struct EncodeWorker: Sendable {
    public var tools: ToolPaths
    public var hasZscale: Bool
    /// CPU niceness for ffmpeg, so the UI and preview stay smooth (Windows: BelowNormal).
    public var niceness: Int32 = 10
    /// Optional: every ffmpeg stderr line of the encode (tests check the encoder's reported settings).
    public var encoderLog: (@Sendable (String) -> Void)?

    public init(tools: ToolPaths, hasZscale: Bool) {
        self.tools = tools
        self.hasZscale = hasZscale
    }

    public func run(jobs: [String], options opt: RunOptions, emit: @escaping WorkerSink) async {
        let dot = Fmt.dot, arrow = Fmt.arrow
        let total = jobs.count
        let t0 = Date()
        var index = 0, ok = 0, failed = 0
        var namer = OutputNamer()
        func log(_ s: String) { emit(.log(s)) }
        @Sendable func setClip(_ path: String, _ status: String, _ state: ItemState, _ progress: Double?, _ detail: String?) {
            emit(.item(path: path, status: status, state: state, progress: progress, detail: detail))
        }
        func overall(_ filePct: Double) {
            let frac = min(1, (Double(index) + filePct / 100) / Double(max(total, 1)))
            let elapsed = Date().timeIntervalSince(t0)
            let eta = frac > 0.01 ? "ETA " + Fmt.clock(elapsed * (1 - frac) / frac) : ""
            emit(.overall(percent: frac * 100, text: "\(min(index + 1, total)) of \(total)", eta: eta))
        }

        if opt.csvEnabled {
            do { try CsvLog.createIfNeeded(opt.csvPath) } catch { log("Could not create CSV log: \(error.localizedDescription)") }
        }

        for file in jobs {
            if Task.isCancelled { break }
            let name = (file as NSString).lastPathComponent
            var outPath: String?
            do {
                guard FileManager.default.fileExists(atPath: file) else { throw ProcessError("source file not found") }
                let outDir = OutputPaths.directory(for: file, mode: opt.outputMode, folder: opt.outputFolder, subfolder: opt.subfolder)
                try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
                let out = namer.next(source: file, directory: outDir, ext: opt.codec.fileExtension)
                outPath = out

                setClip(file, "Analyzing", .active, 0, nil)
                overall(0)

                // Source analysis
                let tools = self.tools
                let info = try await uncancellable { try await Probe.run(ffprobe: tools.ffprobe, path: file) }
                let iso = try await uncancellable { Metadata.parseISO((try? await ProcessRunner.run(tools.exiftool, Metadata.isoArguments(file)))?.lines ?? []) }
                let isFLog2 = try await uncancellable { Metadata.isFLog2((try? await ProcessRunner.run(tools.exiftool, Metadata.userCommentArguments(file)))?.lines ?? []) }
                let isFull = info.isFullRange
                let heat = Heat.bar(info.complexity)
                log("\(name): ISO \(iso.map(String.init) ?? "n/a"), F-Log2 \(isFLog2 ? "yes" : "no"), source range \(isFull ? "full -> zscale to limited" : "limited")")
                if isFull && !hasZscale {
                    throw ProcessError("this clip is full range and needs ffmpeg's zscale filter, which the installed ffmpeg lacks (see Tools in Settings)")
                }

                var signals = ClipSignals()
                if opt.autoCrf || opt.autoGrain {
                    signals = (try? await ClipAnalysis.run(ffmpeg: tools.ffmpeg, path: file)) ?? signals
                    if Task.isCancelled { setClip(file, "Cancelled", .cancelled, 0, nil); break }
                    func r1(_ v: Double?) -> String { v.map { Fmt.num(Fmt.round($0, 1)) } ?? "n/a" }
                    log("\(name): analysis Motion(YDIF)=\(r1(signals.motion)) Colour(SATAVG)=\(r1(signals.colour)) Bright=\(signals.brightMin.map(String.init) ?? "n/a")-\(signals.brightMax.map(String.init) ?? "n/a") NoisePSNR=\(signals.noisePSNR.flatMap { $0 != 0 ? r1($0) : nil } ?? "n/a") dB")
                }

                let grain = AutoRules.grain(manual: opt.grain, auto: opt.autoGrain, isFLog2: isFLog2, iso: iso, psnr: signals.noisePSNR)
                let crf = AutoRules.crf(manual: opt.crf, auto: opt.autoCrf, codec: opt.codec, isFLog2: isFLog2, iso: iso, signals: signals)

                let crfText = opt.autoCrf ? "\(crf) (auto)" : "\(crf)"
                let grainText = grain.name + (opt.autoGrain ? " (auto)" : "")
                var detailBase = "\(opt.codec.displayName) CRF \(crfText) \(dot) Grain \(grainText)"
                if opt.vbrEnabled { detailBase += " \(dot) cap \(Fmt.num(opt.maxRate)) Mbps" }
                if opt.exposure != 0 { detailBase += " \(dot) \(opt.exposureText) EV" }

                let cmd = EncodeCommand(source: file, output: out, codec: opt.codec, crf: crf, grain: grain, cap: opt.cap,
                                        exposure: opt.exposure, lutPath: opt.lutPath, isFullRange: isFull,
                                        width: info.width, height: info.height, trimStart: opt.trimStart, trimEnd: opt.trimEnd)
                if !cmd.filters.isEmpty { log("\(name): filters \(cmd.filters.joined(separator: ","))") }   // the script's chain; BT.709 tagging is appended

                // Remove an existing output so ffmpeg/ExifTool start clean
                if FileManager.default.fileExists(atPath: out) {
                    do { try FileManager.default.removeItem(atPath: out); log("Removed existing file: \(out)") }
                    catch { log("WARNING: Could not remove existing file: \(out)") }
                }
                log("\(name): pixel format \(info.pixelFormat ?? "")")

                let targetDuration = EncodeCommand.targetDuration(source: info.duration, trimStart: opt.trimStart, trimEnd: opt.trimEnd)
                setClip(file, "Encoding 0%", .active, 0, detailBase)
                let tail = LockedBox<[String]>([])
                let progress = ProgressParser(target: targetDuration)
                let indexNow = index
                let encoderLog = self.encoderLog
                let detail = detailBase
                let code = try await ProcessRunner.streamStderr(tools.ffmpeg, cmd.arguments, niceness: niceness) { line in
                    tail.mutate { $0.append(line); if $0.count > 12 { $0.removeFirst() } }
                    encoderLog?(line)
                    guard let p = progress.parse(line) else { return }
                    setClip(file, "Encoding \(Fmt.fixed(p.percent, 0))%", .active, p.percent,
                            detail + (p.speed.map { " \(dot) \($0)x" } ?? ""))
                    let frac = min(1, (Double(indexNow) + p.percent / 100) / Double(max(total, 1)))
                    let elapsed = Date().timeIntervalSince(t0)
                    emit(.overall(percent: frac * 100, text: "\(min(indexNow + 1, total)) of \(total)",
                                  eta: frac > 0.01 ? "ETA " + Fmt.clock(elapsed * (1 - frac) / frac) : ""))
                }

                if Task.isCancelled {
                    try? FileManager.default.removeItem(atPath: out)
                    setClip(file, "Cancelled", .cancelled, 0, detailBase)
                    log("\(name): cancelled, partial output removed.")
                    break
                }
                if code != 0 {
                    try? FileManager.default.removeItem(atPath: out)
                    throw ProcessError("ffmpeg exited with code \(code)\n    " + tail.value.joined(separator: "\n    "))
                }

                // Metadata
                setClip(file, "Metadata", .active, 100, detailBase)
                let ts = try await uncancellable { (try? await ProcessRunner.run(tools.exiftool, Metadata.timestampArguments(file)))?.lines ?? [] }
                let chosen = Metadata.chooseTimestamp(ts)
                if let c = chosen { log("\(name): timestamp source \(c.line)") } else { log("\(name): WARNING no DateTimeOriginal found.") }

                let pass1 = try await uncancellable { try? await ProcessRunner.run(tools.exiftool, Metadata.copyArguments(source: file, output: out)) }
                if pass1?.exitCode != 0 { log("\(name): ExifTool pass 1 failed. Skipping advanced metadata.") } else { log("\(name): core metadata copied.") }

                if let c = chosen {
                    let pass2 = try await uncancellable { try? await ProcessRunner.run(tools.exiftool, Metadata.fileDateArguments(timestamp: c.value, output: out)) }
                    if pass2?.exitCode == 0 { log("\(name): FileCreateDate/ModifyDate set from \(c.value)") }
                    else { log("\(name): WARNING failed to set file system dates") }
                }

                // Sizes + log
                let mb = 1_048_576.0
                let origSize = Double((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)??.int64Value ?? 0)
                let newSize = Double((try? FileManager.default.attributesOfItem(atPath: out)[.size] as? NSNumber)??.int64Value ?? 0)
                let origMB = origSize / mb, newMB = newSize / mb
                let ratio = origMB > 0 ? Fmt.round((1 - newMB / origMB) * 100, 1) : 0
                let notes = CsvLog.notes(codec: opt.codec, iso: iso, isFLog2: isFLog2, isFullRange: isFull,
                                         exposureText: opt.exposureText, vbvText: opt.vbvText)
                log("\(name) -> \(out) | saved \(Fmt.num(ratio))% (\(Fmt.num(Fmt.round(origMB, 1))) -> \(Fmt.num(Fmt.round(newMB, 1))) MB) | CRF=\(crf) Grain=\(grain.rawValue) VBV=\(opt.vbvText) EV=\(opt.exposureText) | Heat \(heat)")
                if opt.csvEnabled {
                    let row = CsvLog.row(name: name, iso: iso, isFLog2: isFLog2, crf: crf, grain: grain, origBitrate: info.streamBitRate,
                                         origSizeMB: origMB, newSizeMB: newMB, ratio: ratio, heat: heat, notes: notes)
                    do { try CsvLog.append(row, to: opt.csvPath) } catch { log("Could not write CSV log: \(error.localizedDescription)") }
                }

                let sizeText = "\(Fmt.upTo1(origMB)) MB \(arrow) \(Fmt.upTo1(newMB)) MB"
                setClip(file, "Done \(ratio >= 0 ? "-" : "+")\(Fmt.num(abs(ratio)))%", .done, 100, "\(sizeText) \(dot) \(detailBase)")
                ok += 1
            } catch {
                _ = outPath
                setClip(file, "Failed", .error, 0, nil)
                log("\(name): FAILED - \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                failed += 1
            }
            index += 1
            overall(0)
        }

        emit(.finished(ok: ok, failed: failed, cancelled: Task.isCancelled, elapsed: Date().timeIntervalSince(t0)))
    }
}

/// Reads ffmpeg's `time=` / `speed=` progress lines.
public struct ProgressParser: Sendable {
    public var target: Double
    public init(target: Double) { self.target = target }

    public struct Progress: Sendable, Equatable {
        public var seconds: Double
        public var percent: Double
        public var speed: String?
    }

    public func parse(_ line: String) -> Progress? {
        guard target > 0, let r = line.range(of: #"time=(\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) else { return nil }
        let parts = line[r].dropFirst(5).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        let cur = h * 3600 + m * 60 + s
        var speed: String?
        if let sr = line.range(of: #"speed=\s*([\d\.]+)x"#, options: .regularExpression) {
            speed = line[sr].dropFirst(6).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "x", with: "")
        }
        return Progress(seconds: cur, percent: min(100, cur / target * 100), speed: speed)
    }
}

/// Scheduled start: "Now", or the next 4 am / 1 pm / 7 pm.
public enum StartSchedule: String, CaseIterable, Sendable, Identifiable {
    case now = "Now", fourAM = "4 am", onePM = "1 pm", sevenPM = "7 pm"
    public var id: String { rawValue }
    var hour: Int? { switch self { case .now: nil; case .fourAM: 4; case .onePM: 13; case .sevenPM: 19 } }

    /// `Get-NextStart`: today at that hour, or tomorrow if it has passed.
    public func nextStart(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard let h = hour else { return now }
        let today = calendar.date(bySettingHour: h, minute: 0, second: 0, of: calendar.startOfDay(for: now))!
        return today <= now ? calendar.date(byAdding: .day, value: 1, to: today)! : today
    }
}
