import Foundation
import ProjectResolution

public enum ToolchainLocatingError: Error, Equatable {
    case xcrunFailed(exitCode: Int32, standardError: String)
    case dylibNotFound(String)
}

/// Resolves the path to the active toolchain's `libIndexStore.dylib` -- kept behind a protocol
/// so `RawIndexStoreClient` can be tested without a real toolchain on disk (a fake returns a
/// canned path). Real resolution: `xcrun --find swift` -> strip `usr/bin/swift` -> append
/// `usr/lib/libIndexStore.dylib`. This mechanism, and the fact that `libIndexStore` is `dlopen`'d
/// at runtime rather than linked at build time, was verified empirically in the Phase 0 spike --
/// see docs/priority-2-phase-0-spike.md.
public protocol ToolchainLocating: Sendable {
    func libIndexStorePath() throws -> String
}

public struct LiveToolchainLocator: ToolchainLocating {
    let processRunning: ProcessRunning
    let fileSystem: FileSystemQuerying

    public init(processRunning: ProcessRunning = LiveProcessRunner(), fileSystem: FileSystemQuerying = LiveFileSystem()) {
        self.processRunning = processRunning
        self.fileSystem = fileSystem
    }

    public func libIndexStorePath() throws -> String {
        let result = try processRunning.run(executable: "xcrun", arguments: ["--find", "swift"], workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw ToolchainLocatingError.xcrunFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        let swiftPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let dylibURL = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent() // usr/bin -> usr
            .deletingLastPathComponent()
            .appendingPathComponent("lib/libIndexStore.dylib")
        guard fileSystem.fileExists(at: dylibURL) else {
            throw ToolchainLocatingError.dylibNotFound(dylibURL.path)
        }
        return dylibURL.path
    }
}
