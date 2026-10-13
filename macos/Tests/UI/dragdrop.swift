// Ideal Video Encoder for macOS - drag-and-drop driver for UI tests
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shows a small window offering the given files/folders as a drag source, then drives a real mouse drag
// (CGEvents: down, drags, up) from it to the target point, as a user dragging from Finder would.
// Usage: dragdrop <targetX> <targetY> <path>...   (global screen coordinates, origin top-left)
// Needs Accessibility permission (posting events); moves the pointer.

import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let tx = Double(args[1]), let ty = Double(args[2]) else {
    print("usage: dragdrop <x> <y> <path>..."); exit(64)
}
let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) }

final class SourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDragged(with event: NSEvent) {
        let items = urls.map { u -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: u.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    override func draw(_ r: NSRect) { NSColor.systemOrange.setFill(); r.fill() }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        print("drag ended, operation \(operation.rawValue)")
        exit(operation.isEmpty ? 2 : 0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let win = NSWindow(contentRect: NSRect(x: 40, y: screen.height - 200, width: 120, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
let view = SourceView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
view.urls = urls
win.contentView = view
win.level = .floating
win.orderFrontRegardless()

// Global top-left coordinates of the source window's centre
let src = CGPoint(x: 100, y: 140)
DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
    func post(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
    post(.mouseMoved, src)
    post(.leftMouseDown, src)
    for i in 1...10 { post(.leftMouseDragged, CGPoint(x: src.x + Double(i) * 3, y: src.y + Double(i) * 3)) }
    let steps = 60
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: src.x + 30 + (tx - src.x - 30) * t, y: src.y + 30 + (ty - src.y - 30) * t))
    }
    usleep(300_000)
    post(.leftMouseDragged, CGPoint(x: tx, y: ty))
    usleep(300_000)
    post(.leftMouseUp, CGPoint(x: tx, y: ty))
    sleep(3)
    print("timed out waiting for the drag to end"); exit(3)
}
app.run()
