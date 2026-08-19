import Foundation

public enum SWBBuildServiceLocatingError: Error, Equatable, CustomStringConvertible {
    case xcodeSelectFailed(exitCode: Int32, standardError: String)
    case bundleNotFound(String)

    public var description: String {
        switch self {
        case .xcodeSelectFailed(let exitCode, let standardError):
            return "`xcode-select -p` failed (exit \(exitCode)): \(standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .bundleNotFound(let path):
            return "SWBBuildService.bundle not found at the expected path in the active Xcode: \(path)"
        }
    }
}

/// Resolves the active Xcode's own bundled `SWBBuildService.bundle` -- mirrors `ToolchainLocating
/// .swift`'s exact shape (`xcode-select`-relative, not hardcoded to one Xcode install) for the same
/// reason: this project must never assume a fixed Xcode path across machines/CI. Confirmed
/// empirically (docs/task-swift-build-prepare-for-indexing-spike.md Step 6) that the real bundle
/// lives at `<Xcode.app>/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/
/// SWBBuildService.bundle`, two path components up from `xcode-select -p`'s own
/// `<Xcode.app>/Contents/Developer` output. Also confirmed (Step 10c) that a client built against
/// one Xcode's `swift-build` snapshot can talk to a materially newer installed Xcode's own bundled
/// service without protocol failure -- this locator deliberately always resolves whichever Xcode
/// is currently active, not a version pinned at build time.
public protocol SWBBuildServiceLocating: Sendable {
    func serviceBundleURL() throws -> URL
}

public struct LiveSWBBuildServiceLocator: SWBBuildServiceLocating {
    let processRunning: ProcessRunning
    let fileSystem: FileSystemQuerying

    public init(processRunning: ProcessRunning = LiveProcessRunner(), fileSystem: FileSystemQuerying = LiveFileSystem()) {
        self.processRunning = processRunning
        self.fileSystem = fileSystem
    }

    public func serviceBundleURL() throws -> URL {
        let result = try processRunning.run(executable: "xcode-select", arguments: ["-p"], workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw SWBBuildServiceLocatingError.xcodeSelectFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        let developerDir = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleURL = URL(fileURLWithPath: developerDir)
            .deletingLastPathComponent() // Contents/Developer -> Contents
            .appendingPathComponent("SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle")
        // `.bundle` is a real directory on disk, not a file -- `fileExists(at:)` deliberately
        // excludes directories (see `LiveFileSystem`'s own implementation), so this must check
        // `directoryExists(at:)` instead, or every real Xcode install would fail this check.
        guard fileSystem.directoryExists(at: bundleURL) else {
            throw SWBBuildServiceLocatingError.bundleNotFound(bundleURL.path)
        }
        return bundleURL
    }
}
