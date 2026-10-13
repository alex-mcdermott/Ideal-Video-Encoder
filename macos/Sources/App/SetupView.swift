// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

/// First-launch tool check: what's missing, how to fix it, and a button that runs
/// install-prerequisites.sh with its output shown live.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var installer = Installer()
    @State private var confirmInstall = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.toolReport?.isComplete == true ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                    .font(.largeTitle)
                    .foregroundStyle(model.toolReport?.isComplete == true ? .green : .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("Tools Setup").font(.title2.bold())
                    Text("Ideal Video Encoder uses ffmpeg, ffprobe and ExifTool from Homebrew.").foregroundStyle(.secondary)
                }
            }

            if let r = model.toolReport {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Tool.allCases) { t in
                        GridRow {
                            Image(systemName: r.paths[t] != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.paths[t] != nil ? .green : .red)
                                .accessibilityHidden(true)
                            Text(t.rawValue).fontWeight(.medium)
                            Text(r.paths[t] ?? "not found").foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(t.rawValue): \(r.paths[t] ?? "not found")")
                    }
                    if r.paths[.ffmpeg] != nil {
                        GridRow {
                            Image(systemName: r.missingEncoders.isEmpty && r.missingFilters.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.missingEncoders.isEmpty && r.missingFilters.isEmpty ? .green : .orange)
                                .accessibilityHidden(true)
                            Text("components").fontWeight(.medium)
                            Text(r.missingEncoders.isEmpty && r.missingFilters.isEmpty
                                 ? "libx265, libsvtav1, zscale, lut3d, lutyuv, libvmaf"
                                 : "missing: " + (r.missingEncoders + r.missingFilters).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if r.problems.isEmpty {
                    Label("Everything is installed.", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(r.problems) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.title).font(.headline)
                                    Text(p.explanation).fixedSize(horizontal: false, vertical: true)
                                    HStack(alignment: .top) {
                                        Text(p.fix)
                                            .font(.system(.callout, design: .monospaced))
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                        Button("Copy") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(p.fix, forType: .string)
                                        }
                                        .accessibilityLabel("Copy fix for \(p.title)")
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: installer.output.isEmpty ? 260 : 150)
                }
            } else {
                ProgressView("Checking tools…")
            }

            if !installer.output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(installer.output.joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .frame(minHeight: 160, maxHeight: 240)
                    .onChange(of: installer.output.count) { _, _ in proxy.scrollTo("end") }
                    .accessibilityLabel("Installer output")
                }
                if let code = installer.exitCode, code != 0 || model.toolReport?.isComplete != true {
                    Text(installer.resultText(code)).foregroundStyle(code == 0 ? .green : .orange)
                }
            }

            HStack {
                Button("Tool Paths…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                Spacer()
                if installer.running { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await model.checkTools(showIfIncomplete: false) } }
                    .disabled(installer.running)
                if model.toolReport?.isComplete == false {
                    Button("Install Missing Tools…") { confirmInstall = true }
                        .disabled(installer.running)
                }
                Button(model.toolReport?.isComplete == true ? "Done" : "Continue Anyway") { model.dismissSetup(); dismissWindow(id: "setup") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installer.running)
            }
        }
        .padding(20)
        .frame(width: 640)
        // Closing the window counts as "Continue Anyway"
        .onDisappear { if model.showSetup && !installer.running { model.dismissSetup() } }
        .confirmationDialog("Install the missing tools with Homebrew?", isPresented: $confirmInstall) {
            Button("Install") { Task { await installer.run(model: model) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(installer.plan(for: model.toolReport))
        }
    }
}

/// Runs the bundled install-prerequisites.sh and collects its output.
@MainActor @Observable
final class Installer {
    var output: [String] = []
    var running = false
    var exitCode: Int32?

    static var scriptPath: String? { Bundle.main.path(forResource: "install-prerequisites", ofType: "sh") }

    func plan(for r: ToolReport?) -> String {
        var lines: [String] = []
        if r?.missingTools.contains(.exiftool) == true { lines.append("• brew install exiftool") }
        if r?.paths[.ffmpeg] == nil || !(r?.missingFilters.isEmpty ?? true) || !(r?.missingEncoders.isEmpty ?? true) {
            lines.append("• Replace Homebrew's ffmpeg with the homebrew-ffmpeg tap build (--with-zimg --with-libvmaf). It compiles from source and can take 10-30 minutes.")
        }
        lines.append("Homebrew itself is never installed for you.")
        return lines.joined(separator: "\n")
    }

    func resultText(_ code: Int32) -> String {
        switch code {
        case 0: "Everything is installed."
        case 2: "Homebrew is not installed. Install it with the command shown above, then try again."
        case 3: "An ffmpeg outside Homebrew is in the way. See the output above."
        default: "Some tools are still missing. See the output above."
        }
    }

    func run(model: AppModel) async {
        guard let script = Self.scriptPath else { output = ["install-prerequisites.sh is missing from the app bundle."]; return }
        running = true
        exitCode = nil
        output = ["$ install-prerequisites.sh"]
        var env: [String: String] = [:]
        if let p = model.settings.ffmpegPath { env["IVE_FFMPEG"] = p }
        if let p = model.settings.ffprobePath { env["IVE_FFPROBE"] = p }
        if let p = model.settings.exiftoolPath { env["IVE_EXIFTOOL"] = p }
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("IVE_") && k != "IVE_SETTINGS_PATH" { env[k] = v }
        let (stream, cont) = AsyncStream<String>.makeStream()
        let task = Task.detached {
            let code = (try? await ProcessRunner.streamStderr("/bin/bash", [script], mergeStdout: true, environment: env) { cont.yield($0) }) ?? 127
            cont.finish()
            return code
        }
        for await line in stream { output.append(line) }
        exitCode = await task.value
        model.appendLog("Tools setup finished with exit code \(exitCode!).")
        running = false
        await model.checkTools(showIfIncomplete: false)
    }
}

/// Settings window: per-tool path overrides.
struct ToolSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(Tool.allCases) { t in
                    HStack {
                        TextField(t.rawValue, text: binding(t), prompt: Text(ToolLocator.locate(t) ?? "not found"))
                            .accessibilityLabel("\(t.rawValue) path")
                        Button("Choose…") { if let p = model.chooseTool(t) { binding(t).wrappedValue = p } }
                            .accessibilityLabel("Choose \(t.rawValue)")
                    }
                }
            } header: {
                Text("Tool locations")
            } footer: {
                Caption("Leave empty to use Homebrew (/opt/homebrew/bin, /usr/local/bin) or PATH. Apps opened from Finder don't see your shell's PATH.")
            }
            HStack {
                Spacer()
                Button("Check Tools") { Task { await model.checkTools(showIfIncomplete: false); model.showSetup = true } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
    }

    func binding(_ t: Tool) -> Binding<String> {
        Binding(get: {
            switch t { case .ffmpeg: model.settings.ffmpegPath ?? ""; case .ffprobe: model.settings.ffprobePath ?? ""; case .exiftool: model.settings.exiftoolPath ?? "" }
        }, set: { v in
            let value: String? = v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
            switch t { case .ffmpeg: model.settings.ffmpegPath = value; case .ffprobe: model.settings.ffprobePath = value; case .exiftool: model.settings.exiftoolPath = value }
        })
    }
}
