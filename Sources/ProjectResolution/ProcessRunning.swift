import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Seam for every subprocess invocation this tool needs (`swift package describe`, `xcodebuild`,
/// `swift build`, `xcrun`) -- so CLI logic that branches on their output/exit code can be tested
/// without actually shelling out, per the architecture spec's testing strategy (section 4).
///
/// `timeout` is a real protocol requirement, not just an extension default with a concrete-type
/// override -- Swift dispatches extension-only methods statically by the *declared* type at the
/// call site, so a `processRunning: ProcessRunning`-typed parameter (every real call site in this
/// project) would always hit the extension's default and never a concrete type's real override.
/// Making it a requirement gets correct dynamic dispatch to whichever conformer actually enforces
/// it. Added for bulk `symbolgraph-extract` calls (`BulkSymbolGraphExtractor`) after real-world use
/// against a large project surfaced a genuine risk: a hung or pathologically slow third-party
/// module could otherwise stall the whole bulk-extraction phase with no way to skip it.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval?) throws -> ProcessResult
}

extension ProcessRunning {
    /// Existing call sites throughout this project only ever needed an untimed invocation --
    /// preserved as a convenience overload so none of them need to change.
    public func run(executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeout: nil)
    }
}

/// Launches via `/usr/bin/env <executable> ...` rather than resolving `executable` to an absolute
/// path itself -- avoids hardcoding toolchain-specific paths (`swift`, `xcodebuild`, `xcrun` are
/// all expected to be on `PATH`), consistent with how this project already locates `libIndexStore`
/// via `xcrun` rather than a baked-in path (see docs/priority-2-phase-0-spike.md).
/// Carries one pipe's fully-read `Data` out of the background queue that reads it --
/// `@unchecked Sendable` is safe here specifically because the write inside the queue's closure
/// always happens-before the `group.wait()` that unblocks the read of `value` afterward, so there
/// is no actual concurrent access.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}

public struct LiveProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var timedOut = false
        var timeoutWorkItem: DispatchWorkItem?
        if let timeout {
            let workItem = DispatchWorkItem {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
            timeoutWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
        }

        // Both pipes must be drained concurrently, never one to completion before the other --
        // confirmed as a real, reproducible deadlock (not theoretical): a child that writes enough
        // to *either* stream while the other is still being read blocks on write() once that
        // stream's kernel pipe buffer fills, which then blocks this process from ever exiting,
        // which then blocks the first readDataToEndOfFile() from ever seeing EOF. Reproduced via a
        // real oracle worker (docs/task-process-tree-optimization.md) whose live cursor-info
        // queries produce substantial real sourcekitd diagnostic noise on stderr while stdout was
        // being read to completion first -- no earlier caller of this function had ever produced
        // enough of both streams at once to hit it.
        //
        // Deliberately real OS threads (`Thread.detachNewThread`), not `DispatchQueue.global()`:
        // confirmed as a second real, reproduced deadlock (`swift test`'s own concurrent test
        // execution) that submitting work to `DispatchQueue.global()` and then *synchronously
        // blocking* on it (`DispatchGroup.wait()`) can starve libdispatch's limited-width
        // cooperative thread pool once enough callers do it at once -- every pool thread ends up
        // parked in `wait()`, so the two just-submitted read tasks this same call needs can never
        // get a thread to run on. A real `Thread` is never drawn from that pool, so blocking this
        // calling thread on it can't shrink the pool available to anyone else.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let stdoutReadDone = DispatchSemaphore(value: 0)
        let stderrReadDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutReadDone.signal()
        }
        Thread.detachNewThread {
            stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrReadDone.signal()
        }
        stdoutReadDone.wait()
        stderrReadDone.wait()
        process.waitUntilExit()
        timeoutWorkItem?.cancel()

        return ProcessResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            standardOutput: String(data: stdoutBox.value, encoding: .utf8) ?? "",
            standardError: timedOut ? "process timed out after \(timeout ?? 0)s" : (String(data: stderrBox.value, encoding: .utf8) ?? "")
        )
    }
}
