// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        // The run bar sits below the split view (an AppKit split view ignores SwiftUI safe-area insets)
        VStack(spacing: 0) {
            VSplitView {
                PreviewPane()
                    .frame(minHeight: 200, idealHeight: 420, maxHeight: .infinity)
                MainTabs()
                    .frame(minHeight: 230, idealHeight: 260, maxHeight: .infinity)
            }
            RunBar()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.openAddPanel() } label: { Label("Add Clips", systemImage: "plus") }
                    .help("Add clips to the queue (⌘O)")
                    .disabled(model.isLocked)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Text(model.cpuText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Processor use")
                    .accessibilityValue(model.cpuText)
                ToolsStatusButton()
                Button { showInspector.toggle() } label: { Label("Settings Inspector", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide the settings inspector" : "Show the settings inspector")
            }
        }
        .navigationTitle("Ideal Video Encoder")
        .navigationSubtitle("HEVC and AV1, 10-bit \(Fmt.dot) LUT and range aware")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.isLocked else { model.appendLog("The queue is locked while \(model.runState == .analysing ? "analysing" : "converting")."); return false }
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                model.add(urls)
            }
            return true
        }
        .overlay {
            if dropTargeted && !model.isLocked {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .alert("Ideal Video Encoder", isPresented: Binding(get: { model.warning != nil }, set: { if !$0 { model.warning = nil } }),
               presenting: model.warning) { _ in
            Button("OK") { model.warning = nil }
        } message: { w in Text(w.text) }
        .sheet(isPresented: $model.showSetup) { SetupView() }
        .task { await model.launchCheck() }
        .frame(minWidth: 960, minHeight: 640)
    }
}

/// Toolbar button showing whether the tools are complete; opens Setup.
struct ToolsStatusButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ok = model.toolReport?.isComplete ?? true
        Button { model.showSetup = true } label: {
            Label(ok ? "Tools" : "Tools need attention", systemImage: ok ? "wrench.and.screwdriver" : "exclamationmark.triangle")
        }
        .foregroundStyle(ok ? Color.primary : Color.orange)
        .help(ok ? "ffmpeg, ffprobe and ExifTool are ready" : "Something the app needs is missing. Click for details.")
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            QueueView()
                .tabItem { Text(model.items.isEmpty ? "Queue" : "Queue (\(model.items.count))") }
                .tag(MainTab.queue)
            AnalysisView()
                .tabItem { Text("Analysis") }
                .tag(MainTab.analysis)
            LogView()
                .tabItem { Text("Log") }
                .tag(MainTab.log)
        }
        .padding([.horizontal, .bottom], 8)
        .padding(.top, 4)
    }
}

// MARK: - Run bar

struct RunBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.overallText).fontWeight(.semibold)
                    .accessibilityLabel("Status")
                    .accessibilityValue(model.overallText)
                Spacer()
                Text(model.etaText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Time")
                    .accessibilityValue(model.etaText)
            }
            ProgressView(value: model.overallPercent, total: 100)
                .accessibilityLabel("Overall progress")
            HStack(spacing: 10) {
                Picker("Start", selection: $model.startWhen) {
                    ForEach(StartWhen.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.runState != .idle)
                .help("When to start")
                .accessibilityLabel("When to start")
                Button {
                    model.startPressed()
                } label: {
                    Label(startLabel, systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.runState == .running || model.runState == .analysing)
                .help("Start converting the queue (⌘↩)")
                Button("Cancel") { model.cancelPressed() }
                    .controlSize(.large)
                    .disabled(model.runState == .idle || model.cancelling)
                    .help("Cancel the scheduled start, conversion or analysis (⌘.)")
            }
            if model.startWhen == .later {
                HStack(spacing: 10) {
                    TextField("Start time", text: $model.settings.scheduleTime, prompt: Text("e.g. 04:30"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 104)
                        .multilineTextAlignment(.center)
                        .disabled(model.runState != .idle)
                        .help("Any time: 04:30, 4:30 pm, 0430, 4pm")
                        .accessibilityLabel("Start time")
                    Text(model.scheduleHint).font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("Schedule")
                        .accessibilityValue(model.scheduleHint)
                    Spacer()
                }
                .onAppear { model.scheduleHint = Schedule.hint(for: model.settings.scheduleTime) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    var startLabel: String {
        switch model.runState {
        case .scheduled: "Start now"
        case .running: "Converting"
        default: "Start"
        }
    }
}

// MARK: - Log

struct LogView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text("[\(line.time)] \(line.text)")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .onChange(of: model.log.count) { _, _ in
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .accessibilityLabel("Log")
            HStack {
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.map { "[\($0.time)] \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                Button("Clear Log") { model.log.removeAll() }
            }
            .padding(6)
        }
    }
}
