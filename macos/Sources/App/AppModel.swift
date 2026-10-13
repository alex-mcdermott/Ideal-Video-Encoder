// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IVECore
import Observation

@MainActor @Observable
final class QueueItem: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    var info: String
    var status = "Queued"
    var state: ItemState = .queued
    var progress = 0.0
    var detail: String

    init(path: String, info: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.info = info
        self.detail = info
    }
}

enum RunState: Equatable { case idle, scheduled, running, analysing }

enum MainTab: Hashable { case queue, analysis, log }

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let time: String
    let text: String
}

struct WarningMessage: Identifiable {
    let id = UUID()
    let text: String
}

/// App state and the actions behind every control (the script's UI helpers and event handlers).
@MainActor @Observable
final class AppModel {
    static let videoExtensions: Set<String> = ["mov", "mp4"]

    var settings: AppSettings { didSet { if settings != oldValue { settingsChanged() } } }
    var items: [QueueItem] = []
    var selection: Set<QueueItem.ID> = []
    var exposure = 0.0
    var trimStart = ""
    var trimEnd = ""
    var runState: RunState = .idle
    var schedule: StartSchedule = .now
    var scheduledAt: Date?
    var overallText = "Ready"
    var etaText = ""
    var overallPercent = 0.0
    var log: [LogLine] = []
    var tab: MainTab = .queue
    var warning: WarningMessage?
    var toolReport: ToolReport?
    var showSetup = false
    var cpuText = ""
    var cancelling = false
    let analysis = AnalysisModel()
    let preview = PreviewModel()

    @ObservationIgnored let store: SettingsStore
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let cpu = CPUMonitor()
    @ObservationIgnored private let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        var loaded = AppSettings()
        var loadError: String?
        do { loaded = try store.load() } catch { loadError = error.localizedDescription }
        settings = loaded
        if let e = loadError { appendLog("Could not read settings: \(e)") }
        analysis.app = self
        preview.app = self
        startTicker()
    }

    // MARK: log and warnings

    func appendLog(_ text: String) {
        log.append(LogLine(time: timeFormat.string(from: Date()), text: text))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    /// `Show-Warning`: log it and tell the user.
    func warn(_ text: String) {
        appendLog(text)
        warning = WarningMessage(text: text)
    }

    // MARK: settings

    private func settingsChanged() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
        preview.requestUpdate()
    }

    func saveSettings() {
        do { try store.save(settings) } catch { appendLog("Could not save settings: \(error.localizedDescription)") }
    }

    var crfText: String {
        get { settings.crf(for: settings.codec) }
        set { settings.setCrf(newValue, for: settings.codec) }
    }

    var currentLut: String? {
        settings.lutEnabled && !settings.lutPath.isEmpty && FileManager.default.fileExists(atPath: settings.lutPath) ? settings.lutPath : nil
    }

    // MARK: tools

    @ObservationIgnored private var didLaunchCheck = false

    /// The launch check runs once even if SwiftUI starts the window's task twice.
    func launchCheck() async {
        guard !didLaunchCheck else { return }
        didLaunchCheck = true
        await checkTools(showIfIncomplete: true)
    }

    func checkTools(showIfIncomplete: Bool) async {
        let report = await ToolReport.check(settings: settings)
        toolReport = report
        if let ff = report.paths[.ffmpeg] { appendLog("Tools: ffmpeg \(ff), ffprobe \(report.paths[.ffprobe] ?? "missing"), exiftool \(report.paths[.exiftool] ?? "missing")") }
        for p in report.problems { appendLog("Setup: \(p.title)") }
        if showIfIncomplete && !report.isComplete {
            // Show the setup sheet again only when what's missing has changed since it was last dismissed
            let key = report.problems.map(\.title).joined(separator: "|")
            if UserDefaults.standard.string(forKey: "DismissedSetupProblems") != key { showSetup = true }
        }
    }

    func dismissSetup() {
        if let r = toolReport { UserDefaults.standard.set(r.problems.map(\.title).joined(separator: "|"), forKey: "DismissedSetupProblems") }
        showSetup = false
    }

    // MARK: queue

    var isLocked: Bool { runState == .running || runState == .analysing }
    var selectedItems: [QueueItem] { items.filter { selection.contains($0.id) } }
    /// `Get-PreviewTarget`: the selected clip, or the first one.
    var previewTarget: QueueItem? { selectedItems.first ?? items.first }

    /// `Add-QueueFiles`: files or folders (top level only), .mov/.mp4, no duplicates.
    func add(_ urls: [URL]) {
        if isLocked { appendLog(runState == .analysing ? "The queue is locked while analysing." : "The queue is locked while converting."); return }
        var files: [String] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                files += names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { url.appendingPathComponent($0).path }
                    .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && !d.boolValue }
            } else {
                files.append(url.path)
            }
        }
        var added: [QueueItem] = []
        for f in files {
            let full = (f as NSString).standardizingPath
            guard Self.videoExtensions.contains((full as NSString).pathExtension.lowercased()) else { continue }
            guard !items.contains(where: { $0.path == full }) else { continue }
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.doubleValue ?? 0
            let item = QueueItem(path: full, info: [Fmt.size(size), (full as NSString).deletingLastPathComponent].joined(separator: "  \(Fmt.dot)  "))
            items.append(item)
            added.append(item)
        }
        guard !added.isEmpty else { return }
        appendLog("Added \(added.count) clip(s).")
        if selection.isEmpty, let first = items.first { selection = [first.id] }
        // Duration needs ffprobe; fill it in when it arrives
        if let ffprobe = toolReport?.paths[.ffprobe] ?? ToolLocator.locate(.ffprobe, override: settings.ffprobePath) {
            for item in added {
                Task {
                    guard let m = try? await Probe.run(ffprobe: ffprobe, path: item.path), m.duration > 0 else { return }
                    let size = (try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.doubleValue ?? 0
                    let info = [Fmt.size(size), Fmt.duration(m.duration), (item.path as NSString).deletingLastPathComponent].joined(separator: "  \(Fmt.dot)  ")
                    if item.detail == item.info { item.detail = info }
                    item.info = info
                }
            }
        }
    }

    func removeSelected() {
        guard !isLocked else { return }
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func clear() {
        guard !isLocked else { return }
        items.removeAll()
        selection = []
        appendLog("Queue cleared.")
    }

    func item(at path: String) -> QueueItem? { items.first { $0.path == path } }

    // MARK: output preview

    var savesTo: String {
        let sample = previewTarget?.path
        if settings.outputMode == .custom && settings.outputFolder.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose an output folder." }
        if OutputPaths.validateSubfolder(settings.subfolder) != nil { return "Invalid folder name." }
        return OutputPaths.preview(sample: sample, mode: settings.outputMode, folder: settings.outputFolder,
                                   subfolder: settings.subfolder, ext: settings.codec.fileExtension)
    }

    // MARK: run

    /// `Get-RunOptions`; warns and returns nil when something is wrong.
    func runOptions(forAnalysis: Bool = false) -> RunOptions? {
        guard let report = toolReport else { warn("Still checking for ffmpeg, ffprobe and ExifTool. Try again in a moment."); return nil }
        if let t = report.missingTools.first { warn("\(t.rawValue) was not found. Open Setup (Tools) to install it or set its path."); return nil }
        do {
            return try RunOptions.validate(settings: settings, exposure: exposure, trimStart: trimStart, trimEnd: trimEnd, forAnalysis: forAnalysis)
        } catch {
            warn((error as? ProcessError)?.message ?? error.localizedDescription)
            return nil
        }
    }

    func startPressed() {
        if runState == .scheduled { startRun(); return }
        guard runState == .idle else { return }
        if items.isEmpty { warn("Add some clips first."); return }
        if schedule == .now { startRun(); return }
        guard runOptions() != nil else { return }   // validate now rather than at 4 am
        scheduledAt = schedule.nextStart()
        runState = .scheduled
        updateScheduleText()
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        appendLog("Queued to start at \(f.string(from: scheduledAt!)).")
    }

    private func updateScheduleText() {
        guard runState == .scheduled, let at = scheduledAt else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        overallText = "Scheduled for \(f.string(from: at))"
        etaText = "Starts in " + Fmt.clock(max(0, at.timeIntervalSinceNow))
    }

    func startRun() {
        guard workerTask == nil, let opt = runOptions(), let report = toolReport, let tools = report.toolPaths else {
            if runState == .scheduled { runState = .idle; overallText = "Ready"; etaText = "" }
            return
        }
        var pending = items.filter { $0.state != .done }
        if pending.isEmpty { pending = items }   // everything done -> re-run the lot
        if pending.isEmpty { appendLog("The queue is empty."); runState = .idle; return }
        for it in pending { it.status = "Waiting"; it.state = .waiting; it.progress = 0; it.detail = it.info }
        saveSettings()
        overallPercent = 0
        etaText = ""
        overallText = "Converting \(pending.count) clip(s)"
        runState = .running
        cancelling = false
        tab = .queue
        appendLog("Started: \(pending.count) clip(s).")

        let worker = EncodeWorker(tools: tools, hasZscale: report.hasZscale)
        let jobs = pending.map(\.path)
        let (stream, cont) = AsyncStream<WorkerEvent>.makeStream()
        let run = Task.detached(priority: .userInitiated) {
            await worker.run(jobs: jobs, options: opt) { cont.yield($0) }
            cont.finish()
        }
        workerTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await e in stream { self?.handle(e) }
            } onCancel: { run.cancel() }
            self?.completeRun()
        }
    }

    func handle(_ e: WorkerEvent) {
        switch e {
        case .log(let t): appendLog(t)
        case .item(let path, let status, let state, let progress, let detail):
            guard let it = item(at: path) else { return }
            it.status = status; it.state = state
            if let p = progress { it.progress = p }
            if let d = detail { it.detail = d }
        case .overall(let pct, let text, let eta):
            overallPercent = pct; overallText = text; etaText = eta
        case .finished(let ok, let failed, let cancelled, let elapsed):
            var summary = "\(ok) converted"
            if failed > 0 { summary += ", \(failed) failed" }
            if cancelled { summary += ", cancelled" }
            overallText = "Finished"
            etaText = "\(summary) \(Fmt.dot) \(Fmt.clock(elapsed))"
            if !cancelled { overallPercent = 100 }
            appendLog("Finished: \(summary).")
        }
    }

    /// `Complete-Run`: anything left waiting goes back to Queued.
    private func completeRun() {
        workerTask = nil
        for it in items where it.state == .waiting || it.state == .active {
            it.status = "Queued"; it.state = .queued; it.progress = 0; it.detail = it.info
        }
        cancelling = false
        runState = .idle
    }

    func cancelPressed() {
        switch runState {
        case .scheduled:
            runState = .idle
            scheduledAt = nil
            overallText = "Ready"; etaText = ""
            appendLog("Scheduled start cancelled.")
        case .running:
            cancelling = true
            overallText = "Cancelling"
            appendLog("Cancelling the queue...")
            workerTask?.cancel()
        case .analysing:
            cancelling = true
            overallText = "Cancelling"
            appendLog("Cancelling the analysis...")
            analysis.cancel()
        case .idle: break
        }
    }

    /// Stops any run and waits for ffmpeg to be killed and partial files removed (used when quitting).
    func stopForQuit() async {
        workerTask?.cancel()
        analysis.cancel()
        while workerTask != nil || analysis.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        saveSettings()
    }

    // MARK: ticker: schedule countdown and CPU

    private func startTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let pct = self.cpu.sample() { self.cpuText = "CPU \(Int(pct.rounded()))%" }
                if self.runState == .scheduled, let at = self.scheduledAt {
                    if at.timeIntervalSinceNow <= 0 { self.startRun() } else { self.updateScheduleText() }
                }
            }
        }
    }
}

/// Whole-machine CPU use from host_processor_info deltas.
final class CPUMonitor {
    private var last: (busy: UInt64, total: UInt64)?

    func sample() -> Double? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { last = (busy, total) }
        guard let l = last, total > l.total else { return nil }
        return Double(busy - l.busy) / Double(total - l.total) * 100
    }
}
