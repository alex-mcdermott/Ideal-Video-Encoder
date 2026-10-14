// Ideal Video Encoder for macOS - accessibility driver for end-to-end UI tests
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Drives the running app through the macOS accessibility API (needs Accessibility permission).
// Elements are found by description, title or value (exact match first, then prefix), depth first.
//
//   axdo <pid> dump                       print the window tree (role, description, value)
//   axdo <pid> press <label>              AXPress a button/checkbox/radio button/menu item
//   axdo <pid> set <label> <value>        set a text field / slider value (then confirms with Return)
//   axdo <pid> increment|decrement <label> [n]   step a slider n times
//   axdo <pid> scroll <label> <0...1>     scroll the scroll area holding an element (1 = bottom)
//   axdo <pid> get <label>                print an element's value
//   axdo <pid> select-row <index>         select row N (0-based) of the first outline/table
//   axdo <pid> select-rows <i,j,...>      select several rows
//   axdo <pid> menu <title>               choose an item in the open pop-up menu
//   axdo <pid> key <code> [cmd|shift|...] send a key press to the app
//   axdo <pid> exists <label>             exit 0 if found
//   axdo <pid> windows                    print window titles and sizes

import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: axdo <pid> <command> ...\n".utf8)); exit(64)
}
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ o: AnyObject?) -> String {
    if let s = o as? String { return s }
    if let n = o as? NSNumber { return n.stringValue }
    return ""
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func labels(_ e: AXUIElement) -> [String] {
    [str(attr(e, kAXDescriptionAttribute)), str(attr(e, kAXTitleAttribute)), str(attr(e, kAXValueAttribute))].filter { !$0.isEmpty }
}

func all(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 60 else { return [] }
    return [root] + children(root).flatMap { all($0, depth: depth + 1) }
}

func find(_ label: String, roles: Set<String>? = nil) -> AXUIElement? {
    let everything = windows().flatMap { all($0) } + ((attr(app, kAXMenuBarAttribute)).map { all($0 as! AXUIElement) } ?? [])
    let pool = everything.filter { roles == nil || roles!.contains(str(attr($0, kAXRoleAttribute))) }
    // description/title exact, then description component (SwiftUI joins "title, label"), then prefix
    if let e = pool.first(where: { el in [str(attr(el, kAXDescriptionAttribute)), str(attr(el, kAXTitleAttribute))].contains(label) }) { return e }
    if let e = pool.first(where: { str(attr($0, kAXDescriptionAttribute)).components(separatedBy: ", ").contains(label) }) { return e }
    return pool.first(where: { labels($0).contains { $0.hasPrefix(label) } })
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.postToPid(pid)
        usleep(30_000)
    }
}

switch args[2] {
case "dump":
    func walk(_ e: AXUIElement, _ d: Int) {
        let role = str(attr(e, kAXRoleAttribute)) + { let sr = str(attr(e, kAXSubroleAttribute)); return sr.isEmpty ? "" : "/" + sr }()
        let desc = str(attr(e, kAXDescriptionAttribute))
        let help = str(attr(e, kAXHelpAttribute))
        let title = str(attr(e, kAXTitleAttribute)), val = str(attr(e, kAXValueAttribute))
        let enabled = (attr(e, kAXEnabledAttribute) as? Bool) ?? true
        var line = String(repeating: "  ", count: d) + role
        if !title.isEmpty { line += " title=\"\(title)\"" }
        if !desc.isEmpty { line += " desc=\"\(desc)\"" }
        if !val.isEmpty { line += " value=\"\(val.prefix(70))\"" }
        if desc.isEmpty && title.isEmpty && !help.isEmpty { line += " help=\"\(help.prefix(50))\"" }
        if !enabled { line += " DISABLED" }
        print(line)
        for c in children(e) { walk(c, d + 1) }
    }
    for w in windows() { walk(w, 0) }

case "windows":
    for w in windows() {
        var size = CGSize.zero
        if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        print("\(str(attr(w, kAXTitleAttribute))) \(Int(size.width))x\(Int(size.height)) sheets=\(children(w).filter { str(attr($0, kAXRoleAttribute)) == "AXSheet" }.count)")
    }

case "press":
    guard args.count > 3, let e = find(args[3], roles: ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXPopUpButton", "AXMenuButton"]) else { fail("not found: \(args.dropFirst(3).joined())") }
    let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
    if r != .success { fail("press failed: \(r.rawValue)") }

case "set":
    guard args.count > 4, let e = find(args[3], roles: ["AXTextField", "AXSlider", "AXTextArea", "AXComboBox"]) else { fail("not found: \(args[3])") }
    let role = str(attr(e, kAXRoleAttribute))
    if role == "AXSlider" {
        guard let v = Double(args[4]) else { fail("number needed") }
        let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, NSNumber(value: v))
        if r != .success { fail("set failed: \(r.rawValue)") }
    } else {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(100_000)
        let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFString)
        if r != .success { fail("set failed: \(r.rawValue)") }
        usleep(100_000)
        key(36)   // Return commits SwiftUI text fields
    }

case "increment", "decrement":
    // SwiftUI sliders ignore a set value; step them with AXIncrement / AXDecrement
    guard args.count > 3, let e = find(args[3], roles: ["AXSlider", "AXIncrementor", "AXStepper"]) else { fail("not found: \(args[3])") }
    let n = args.count > 4 ? Int(args[4]) ?? 1 : 1
    for _ in 0..<n {
        AXUIElementPerformAction(e, (args[2] == "increment" ? kAXIncrementAction : kAXDecrementAction) as CFString)
        usleep(40_000)
    }

case "scroll":
    // Scrolls the scroll area holding an element: axdo <pid> scroll <label> <0...1>
    guard args.count > 4, var e = find(args[3]), let v = Double(args[4]) else { fail("usage: scroll <label> <0...1>") }
    while str(attr(e, kAXRoleAttribute)) != "AXScrollArea" {
        guard let p = attr(e, kAXParentAttribute) else { fail("not in a scroll area: \(args[3])") }
        e = p as! AXUIElement
    }
    guard let bar = attr(e, kAXVerticalScrollBarAttribute) else { fail("no vertical scroll bar") }
    let r = AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, NSNumber(value: v))
    if r != .success { fail("scroll failed: \(r.rawValue)") }

case "get":
    guard args.count > 3, let e = find(args[3]) else { fail("not found: \(args[3])") }
    print(str(attr(e, kAXValueAttribute)))

case "exists":
    exit(args.count > 3 && find(args[3]) != nil ? 0 : 1)

case "select-row", "select-rows":
    guard args.count > 3 else { fail("index needed") }
    let idx = Set(args[3].split(separator: ",").compactMap { Int($0) })
    guard let table = windows().flatMap({ all($0) }).first(where: { ["AXOutline", "AXTable"].contains(str(attr($0, kAXRoleAttribute))) }) else { fail("no list") }
    let rows = children(table).filter { str(attr($0, kAXRoleAttribute)) == "AXRow" }
    let picked = rows.enumerated().filter { idx.contains($0.offset) }.map(\.element)
    guard !picked.isEmpty else { fail("row out of range (\(rows.count) rows)") }
    let r = AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, picked as CFArray)
    if r != .success { for p in picked { AXUIElementSetAttributeValue(p, kAXSelectedAttribute as CFString, kCFBooleanTrue) } }
    AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue)

case "menu":
    guard args.count > 3, let e = find(args[3], roles: ["AXMenuItem"]) else { fail("menu item not found: \(args[3])") }
    AXUIElementPerformAction(e, kAXPressAction as CFString)

case "key":
    guard args.count > 3, let code = CGKeyCode(args[3]) else { fail("key code needed") }
    var flags: CGEventFlags = []
    for m in args.dropFirst(4) {
        switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break }
    }
    key(code, flags: flags)

default:
    fail("unknown command \(args[2])")
}
