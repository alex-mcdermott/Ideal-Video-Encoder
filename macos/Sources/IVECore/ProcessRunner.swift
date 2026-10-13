// Ideal Video Encoder for macOS
// https://github.com/alex-mcdermott/Ideal-Video-Encoder
// Copyright (C) 2026 the Ideal Video Encoder contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// Non-empty stdout lines (as `Invoke-Hidden` returns them).
    public var lines: [String] { stdoutText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty } }
}

public struct ProcessError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Holds the running child so a Swift task cancellation can kill it.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    func started(_ p: pid_t) {
        lock.lock(); pid = p; let kill = cancelled; lock.unlock()
        if kill { Darwin.kill(p, SIGKILL) }
    }
    func finished() { lock.lock(); pid = 0; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let p = pid; lock.unlock()
        if p > 0 { Darwin.kill(p, SIGKILL) }
    }
}

/// Runs external tools with an argument array (no shell). Blocking pipe reads happen on
/// dispatch threads, not on the Swift concurrency pool. Cancelling the calling task kills the child.
public enum ProcessRunner {
    /// Environment for children: GUI apps get a minimal PATH, so add Homebrew's folders
    /// (exiftool is a Perl script and ffmpeg may look up helpers).
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ToolLocator.searchDirectories
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra + current.filter { !extra.contains($0) }).joined(separator: ":")
        return env
    }

    private static func makeProcess(_ executable: String, _ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = childEnvironment
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Run to completion and capture stdout and stderr.
    public static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = makeProcess(executable, arguments)
                    let out = Pipe(), err = Pipe()
                    p.standardOutput = out
                    p.standardError = err
                    do { try p.run() } catch {
                        cont.resume(throwing: ProcessError("Could not start \(executable): \(error.localizedDescription)"))
                        return
                    }
                    handle.started(p.processIdentifier)
                    let group = DispatchGroup()
                    let errBox = DataBox()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    p.waitUntilExit()
                    handle.finished()
                    cont.resume(returning: ProcessResult(exitCode: p.terminationStatus, stdout: outData, stderr: errBox.data))
                }
            }
        } onCancel: { handle.cancel() }
    }

    /// Run and deliver stderr line by line (ffmpeg ends progress lines with `\r`, so both `\r` and
    /// `\n` end a line, as .NET's ReadLine does). `niceness` lowers the child's CPU priority.
    /// Returns the exit status; a killed process returns the signal number.
    public static func streamStderr(_ executable: String, _ arguments: [String], niceness: Int32 = 0,
                                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = makeProcess(executable, arguments)
                    let err = Pipe()
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = err
                    do { try p.run() } catch {
                        cont.resume(throwing: ProcessError("Could not start \(executable): \(error.localizedDescription)"))
                        return
                    }
                    if niceness != 0 { setpriority(PRIO_PROCESS, id_t(p.processIdentifier), niceness) }
                    handle.started(p.processIdentifier)
                    let fh = err.fileHandleForReading
                    var buffer = Data()
                    func flush(final: Bool) {
                        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                            let line = buffer[buffer.startIndex..<i]
                            var next = buffer.index(after: i)
                            if buffer[i] == 0x0D, next < buffer.endIndex, buffer[next] == 0x0A { next = buffer.index(after: next) }
                            if buffer[i] == 0x0D, next == buffer.endIndex, !final { return }   // might be \r\n split across reads
                            onLine(String(decoding: line, as: UTF8.self))
                            buffer = Data(buffer[next...])
                        }
                        if final, !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
                    }
                    while true {
                        let d = fh.availableData
                        if d.isEmpty { break }
                        buffer.append(d)
                        flush(final: false)
                    }
                    flush(final: true)
                    p.waitUntilExit()
                    handle.finished()
                    cont.resume(returning: p.terminationStatus)
                }
            }
        } onCancel: { handle.cancel() }
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }
