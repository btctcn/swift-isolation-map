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
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult
}

/// Launches via `/usr/bin/env <executable> ...` rather than resolving `executable` to an absolute
/// path itself -- avoids hardcoding toolchain-specific paths (`swift`, `xcodebuild`, `xcrun` are
/// all expected to be on `PATH`), consistent with how this project already locates `libIndexStore`
/// via `xcrun` rather than a baked-in path (see docs/priority-2-phase-0-spike.md).
public struct LiveProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult {
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
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
