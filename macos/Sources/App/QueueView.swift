// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import IVECore
import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    QueueRow(item: item, isSelected: model.selection.contains(item.id)).tag(item.id)
                }
            }
            .contextMenu(forSelectionType: QueueItem.ID.self) { ids in
                Button("Preview") { model.selection = ids; model.preview.start() }.disabled(ids.isEmpty)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.items.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) })
                }.disabled(ids.isEmpty)
                Divider()
                Button("Remove") { model.selection = ids; model.removeSelected() }.disabled(ids.isEmpty || model.isLocked)
            } primaryAction: { ids in
                // Double-click or Return: preview
                model.selection = ids
                model.preview.start()
            }
            .onDeleteCommand { model.removeSelected() }
            .disabled(false)
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView {
                        Label("Drop clips here", systemImage: "film.stack")
                    } description: {
                        Text("Drop .MOV or .MP4 files or folders onto the window, or click Add Clips.")
                    }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Queue")

            HStack(spacing: 8) {
                Button { model.openAddPanel() } label: { Label("Add Clips…", systemImage: "plus") }
                    .disabled(model.isLocked)
                    .help("Add clips to the queue (⌘O)")
                Button { model.removeSelected() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(model.isLocked || model.selection.isEmpty)
                    .help("Remove the selected clips (Delete)")
                Button("Clear") { model.clear() }
                    .disabled(model.isLocked || model.items.isEmpty)
                    .help("Remove every clip from the queue")
                Spacer()
                if model.isLocked {
                    Label("Queue locked while \(model.runState == .analysing ? "analysing" : "converting")", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}

struct QueueRow: View {
    let item: QueueItem
    /// On a highlighted row accent-coloured text vanishes, so the note uses the primary style there
    var isSelected = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if !item.note.isEmpty {
                    Text(item.note).font(.callout)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
                        .lineLimit(1).truncationMode(.tail)
                }
                if item.state == .active {
                    ProgressView(value: item.progress, total: 100).controlSize(.small)
                        .accessibilityLabel("Progress for \(item.name)")
                }
            }
            Spacer(minLength: 8)
            StatusBadge(text: item.status, state: item.state)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.status)")
        .accessibilityValue(item.note.isEmpty ? item.detail : item.detail + ". " + item.note)
    }
}

struct StatusBadge: View {
    let text: String
    let state: ItemState

    var color: Color {
        switch state {
        case .done: .green
        case .error: .red
        case .active: .accentColor
        case .cancelled: .orange
        case .queued, .waiting: .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(state == .queued || state == .waiting ? Color.secondary : color)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}
