import Foundation
import ProjectResolution

public enum SourceKitDLocatingError: Error, Equatable {
    case xcrunFailed(exitCode: Int32, standardError: String)
    case dylibNotFound(String)
}

/// Resolves the active toolchain's `sourcekitdInProc` dylib path -- mirrors
/// `IndexStoreIntegration/ToolchainLocating.swift`'s exact shape (`xcrun --find swift` -> strip
/// `usr/bin/swift` -> append a fixed relative path), but note the two mechanisms are *not* the
/// same underneath: `libIndexStore.dylib` is dlopen'd via the `indexstore-db` Swift package's own
/// wrapper, while `sourcekitdInProc` has no such wrapper -- this project dlopens it directly (see
/// `SourceKitDClient.swift`). Path confirmed empirically on the reference machine (Xcode 26.4.0):
/// `usr/lib/sourcekitdInProc.framework/sourcekitdInProc` is a real, `dlopen`-able Mach-O dylib
/// (a symlink to `Versions/Current/...`, which `dlopen` follows transparently -- no need to
/// resolve it ourselves).
public protocol SourceKitDLocating: Sendable {
    func sourcekitdInProcPath() throws -> String
}

public struct LiveSourceKitDLocator: SourceKitDLocating {
    let processRunning: ProcessRunning
    let fileSystem: FileSystemQuerying

    public init(processRunning: ProcessRunning = LiveProcessRunner(), fileSystem: FileSystemQuerying = LiveFileSystem()) {
        self.processRunning = processRunning
        self.fileSystem = fileSystem
    }

    public func sourcekitdInProcPath() throws -> String {
        let result = try processRunning.run(executable: "xcrun", arguments: ["--find", "swift"], workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw SourceKitDLocatingError.xcrunFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        let swiftPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let dylibURL = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent() // usr/bin -> usr
            .deletingLastPathComponent()
            .appendingPathComponent("lib/sourcekitdInProc.framework/sourcekitdInProc")
        guard fileSystem.fileExists(at: dylibURL) else {
            throw SourceKitDLocatingError.dylibNotFound(dylibURL.path)
        }
        return dylibURL.path
    }
}
