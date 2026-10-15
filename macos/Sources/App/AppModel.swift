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
    /// Per-clip analysis note (v1.1), shown under the detail line
    var note = ""

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
    /// Output speed (v1.3); session state like exposure and trim, not saved
    var speed = 1.0 { didSet { if speed != oldValue { updateNotes(); preview.requestUpdate() } } }
    /// "Replace with a music file" and the chosen file (v1.3); not saved
    var musicOn = false { didSet { if musicOn != oldValue { preview.requestUpdate() } } }
    var musicPath = "" { didSet { if musicPath != oldValue { preview.requestUpdate() } } }
    var runState: RunState = .idle
    var startWhen: StartWhen = .now
    var scheduleHint = ""
    /// Per-clip CRF/cap/grain from "Use per clip" or a quality-target run, by source path
    var clipOverrides: [String: ClipOverride] = [:] { didSet { updateNotes() } }
    var scheduledAt: Date?
    var overallText = "Ready"
    var etaText = ""
    var overallPercent = 0.0
    var log: [LogLine] = []
    var tab: MainTab = .queue
    var warning: WarningMessage?
    var toolReport: ToolReport?
    /// Tools Setup is a separate window (a sheet would block Quit); bump `setupRequests` to bring it forward.
    var showSetup = false { didSet { if showSetup && !oldValue { setupRequests += 1 } } }
    var setupRequests = 0
    var cpuText = ""
    var cancelling = false
    /// View > Bigger / Smaller (index into TextSize.steps); a per-Mac preference, not in settings.json.
    /// IVE_TEXT_SIZE (0-3) overrides it for tests.
    var textSizeStep: Int = {
        if let v = ProcessInfo.processInfo.environment["IVE_TEXT_SIZE"].flatMap(Int.init) { return min(max(v, 0), TextSize.steps.count - 1) }
        return min(max(UserDefaults.standard.integer(forKey: TextSize.key), 0), TextSize.steps.count - 1)
    }() {
        didSet { if ProcessInfo.processInfo.environment["IVE_TEXT_SIZE"] == nil { UserDefaults.standard.set(textSizeStep, forKey: TextSize.key) } }
    }
    var textScale: CGFloat { TextSize.steps[textSizeStep] }
    let analysis = AnalysisModel()
    let preview = PreviewModel()

    @ObservationIgnored let store: SettingsStore
    /// Consumes worker events until the worker finishes; never cancelled itself, so the worker's last
    /// events (Cancelled status, log, summary) still arrive after Cancel.
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    /// The worker; cancelling it kills ffmpeg and stops the queue.
    @ObservationIgnored private var workerRun: Task<Void, Never>?
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

    /// `Get-LookKey` for the current settings.
    var lookKey: String { RunOptions.lookKey(settings: settings, exposure: exposure, speed: speed) }

    /// The music file the preview and encode use: only with audio and "Replace with a music file" on.
    var activeMusic: String? {
        settings.audioEnabled && musicOn && !musicPath.isEmpty && FileManager.default.fileExists(atPath: musicPath) ? musicPath : nil
    }

    /// `Update-OverrideNotes`.
    func updateNotes() {
        let key = lookKey
        for it in items { it.note = clipOverrides[it.path]?.note(currentKey: key) ?? "" }
    }

    private func settingsChanged() {
        updateNotes()
        if startWhen == .later { scheduleHint = Schedule.hint(for: settings.scheduleTime) }
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
        updateNotes()
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
        for it in items where selection.contains(it.id) { clipOverrides[it.path] = nil }
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func clear() {
        guard !isLocked else { return }
        items.removeAll()
        clipOverrides.removeAll()
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
            return try RunOptions.validate(settings: settings, exposure: exposure, trimStart: trimStart, trimEnd: trimEnd,
                                          speed: speed, musicOn: musicOn, musicPath: musicPath, forAnalysis: forAnalysis)
        } catch {
            warn((error as? ProcessError)?.message ?? error.localizedDescription)
            return nil
        }
    }

    func startPressed() {
        if runState == .scheduled { startRun(); return }
        guard runState == .idle else { return }
        if items.isEmpty { warn("Add some clips first."); return }
        if startWhen == .now { startRun(); return }
        guard let t = Schedule.parse(settings.scheduleTime) else { warn("Enter a start time, for example 04:30 or 4:30 pm."); return }
        guard runOptions() != nil else { return }   // validate now rather than at the scheduled time
        scheduledAt = Schedule.nextStart(t)
        saveSettings()
        runState = .scheduled
        updateScheduleText()
        appendLog("Queued to start at \(Schedule.localStart(scheduledAt!)).")
    }

    private func updateScheduleText() {
        guard runState == .scheduled, let at = scheduledAt else { return }
        overallText = "Scheduled for " + Schedule.localStart(at, zone: false)
        etaText = "Starts in " + Schedule.countdown(at.timeIntervalSinceNow)
    }

    func startRun() {
        guard workerTask == nil, var opt = runOptions(), let report = toolReport, let tools = report.toolPaths else {
            if runState == .scheduled { runState = .idle; overallText = "Ready"; etaText = "" }
            return
        }
        var pending = items.filter { $0.state != .done }
        if pending.isEmpty { pending = items }   // everything done -> re-run the lot
        if pending.isEmpty { appendLog("The queue is empty."); runState = .idle; return }
        for it in pending { it.status = "Waiting"; it.state = .waiting; it.progress = 0; it.detail = it.info }
        for it in pending { if let o = clipOverrides[it.path] { opt.overrides[it.path] = o } }
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
        workerRun = run
        workerTask = Task { [weak self] in
            for await e in stream { self?.handle(e) }
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
        case .clipResult(let path, let result, let remember):
            if remember { clipOverrides[path] = result }
        case .analysisFinished: break
        }
    }

    /// `Complete-Run`: anything left waiting goes back to Queued.
    private func completeRun() {
        workerTask = nil
        workerRun = nil
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
            workerRun?.cancel()
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
        workerRun?.cancel()
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
                } else if self.runState == .idle && self.startWhen == .later {
                    self.scheduleHint = Schedule.hint(for: self.settings.scheduleTime)   // keep "in 5 h 32 min" current
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
