// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

/// Analysis tab state: each clip analysed on its own, then used per clip or applied to all (v1.1).
@MainActor @Observable
final class AnalysisModel {
    @ObservationIgnored weak var app: AppModel?
    var items: [QueueItem] = []
    var target = 95
    var isRunning = false
    /// Latest results, by path (not yet applied)
    var results: [String: ClipOverride] = [:]
    var suggestion: AnalysisSuggestion?
    /// Event consumer (not cancelled, so the worker's final events arrive) and the worker itself.
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run: Task<Void, Never>?

    static let targets = [(93, "High (VMAF 93)"), (95, "Transparent (VMAF 95)"), (97, "Archival (VMAF 97)")]

    /// "Analyse 3 selected" / "Analyse selected" / "Analyse all"
    var primaryLabel: String {
        let n = app?.selection.count ?? 0
        return n > 1 ? "Analyse \(n) selected" : n == 1 ? "Analyse selected" : "Analyse all"
    }

    /// `Start-Analysis`: the selected clips, or the whole queue (`all`, or when nothing is selected).
    func start(all: Bool) {
        guard let app, task == nil, app.runState == .idle else { return }
        var targets = all ? app.items : app.selectedItems
        if targets.isEmpty { targets = app.items }
        if targets.isEmpty { app.warn("Add some clips first."); return }
        guard let report = app.toolReport, let tools = report.toolPaths else { app.warn("ffmpeg, ffprobe and ExifTool are needed. Open Tools Setup."); return }
        guard report.hasVmaf else {
            app.warn("Your ffmpeg build has no libvmaf filter, which the analysis needs. Open Tools Setup to install an ffmpeg that has it.")
            return
        }
        guard var opt = app.runOptions(forAnalysis: true) else { return }
        opt.targetVmaf = Double(target)

        items = targets.map { t in
            let a = QueueItem(path: t.path, info: t.info)
            a.status = "Waiting"; a.state = .waiting
            return a
        }
        results = [:]
        suggestion = nil
        app.overallPercent = 0
        app.etaText = ""
        app.overallText = "Analysing \(targets.count) clip(s)"
        app.runState = .analysing
        app.cancelling = false
        isRunning = true
        app.tab = .analysis
        app.appendLog("Analysis started: \(targets.count) clip(s), target VMAF \(target).")

        let worker = AnalysisWorker(tools: tools)
        let jobs = targets.map(\.path)
        let (stream, cont) = AsyncStream<WorkerEvent>.makeStream()
        let run = Task.detached(priority: .userInitiated) {
            _ = await worker.run(jobs: jobs, options: opt) { cont.yield($0) }
            cont.finish()
        }
        self.run = run
        task = Task { [weak self] in
            for await e in stream { self?.handle(e) }
            self?.complete()
        }
    }

    private func handle(_ e: WorkerEvent) {
        guard let app else { return }
        switch e {
        case .log(let t): app.appendLog(t)
        case .item(let path, let status, let state, let progress, let detail):
            guard let it = items.first(where: { $0.path == path }) else { return }
            it.status = status; it.state = state
            if let p = progress { it.progress = p }
            if let d = detail { it.detail = d }
        case .overall(let pct, let text, let eta):
            app.overallPercent = pct; app.overallText = text; app.etaText = eta
        case .clipResult(let path, let result, _):
            results[path] = result
        case .analysisFinished(let cancelled, let s, let elapsed):
            app.overallText = "Analysis finished"
            app.etaText = (cancelled ? "cancelled" : "\(s?.count ?? 0) clip(s)") + " \(Fmt.dot) " + Fmt.clock(elapsed)
            if !cancelled { app.overallPercent = 100 }
            suggestion = s
            app.appendLog("Analysis finished" + (s.map { ": CRF \($0.crf), cap \($0.cap) Mbps" } ?? "") + ".")
        case .finished: break
        }
    }

    private func complete() {
        task = nil
        run = nil
        isRunning = false
        for it in items where it.state == .waiting || it.state == .active {
            it.status = "Not analysed"; it.state = .cancelled; it.progress = 0
        }
        app?.cancelling = false
        app?.runState = .idle
    }

    func cancel() { run?.cancel() }

    var summaryText: String {
        guard let s = suggestion else { return "" }
        return s.count > 1
            ? "Each clip has its own suggestion. Use them per clip, or apply CRF \(s.crf) with a \(s.cap) Mbps cap to everything (the most demanding clip's CRF and the largest cap)."
            : "Suggested: CRF \(s.crf) with a \(s.cap) Mbps cap. Use it for this clip only, or apply it to everything."
    }

    /// "Use per clip": each analysed clip still in the queue encodes with its own CRF and cap.
    func usePerClip() {
        guard let app else { return }
        var n = 0
        for (path, r) in results where app.item(at: path) != nil { app.clipOverrides[path] = r; n += 1 }
        app.appendLog("Per-clip settings applied to \(n) clip(s); each will encode with its own CRF and cap.")
        app.tab = .queue
    }

    /// "Apply to all": one CRF and cap for everything; drops the per-clip results and the quality target.
    func applyToAll() {
        guard let app, let s = suggestion else { return }
        for path in results.keys { app.clipOverrides[path] = nil }
        if app.settings.codec != s.codec {
            app.appendLog("The analysis was for \(s.codec.displayName); switching the codec back to it.")
            app.settings.codec = s.codec
        }
        app.settings.qualityTarget = 0
        app.settings.autoCrf = false
        app.settings.setCrf(String(s.crf), for: s.codec)
        app.settings.vbrEnabled = true
        app.settings.maxRate = String(s.cap)
        app.saveSettings()
        app.appendLog("Applied analysis suggestion: CRF \(s.crf), \(s.cap) Mbps cap.")
    }
}

struct AnalysisView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ana = model.analysis
        @Bindable var bana = ana
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("Analyses each clip on its own (the selected clips, or every clip from the arrow menu): short sample encodes with your current look and grain settings, scored against the source with VMAF, give each clip its own CRF and bitrate cap. Several minutes per 6K clip.")
                    .appFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Picker("Analysis quality target", selection: $bana.target) {
                    ForEach(AnalysisModel.targets, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Quality target. VMAF 100 = indistinguishable from the source")
                .disabled(model.runState != .idle)
                // Split button: the main part analyses the selection, the arrow offers both choices
                HStack(spacing: 1) {
                    Button { ana.start(all: false) } label: {
                        Label(ana.primaryLabel, systemImage: "chart.xyaxis.line")
                    }
                    .help("Analyse the selected clips (all clips if none are selected)")
                    Menu {
                        Button("Analyse all clips") { ana.start(all: true) }
                        Button("Analyse selected clips") { ana.start(all: false) }
                            .disabled(model.selection.isEmpty)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More analysis options")
                    .accessibilityLabel("More analysis options")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(model.runState != .idle || model.items.isEmpty)
            }

            List {
                ForEach(ana.items) { item in
                    AnalysisRow(item: item)
                }
            }
            .overlay {
                if ana.items.isEmpty {
                    ContentUnavailableView {
                        Label("Find the right CRF and cap for your footage", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("Pick a quality target and press Analyse.")
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Analysis results")

            if ana.suggestion != nil && !ana.isRunning {
                HStack(spacing: 10) {
                    Text(ana.summaryText).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Use per clip") { ana.usePerClip() }
                        .buttonStyle(.borderedProminent)
                        .help("Each analysed clip encodes with its own CRF and cap")
                    Button("Apply to all (CRF \(ana.suggestion!.crf), \(ana.suggestion!.cap) Mbps)") { ana.applyToAll() }
                        .help("Use one CRF and cap for everything: the most demanding clip's CRF and the largest cap")
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Analysis suggestion")
            }
        }
        .padding(6)
    }
}

struct AnalysisRow: View {
    let item: QueueItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).appFont(.headline).lineLimit(1).truncationMode(.middle)
                Text(item.detail).appFont(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if item.state == .active {
                    ProgressView(value: item.progress, total: 100).controlSize(.small)
                        .accessibilityLabel("Analysis progress for \(item.name)")
                }
            }
            Spacer(minLength: 8)
            StatusBadge(text: item.status, state: item.state)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.status)")
        .accessibilityValue(item.detail)
    }
}
