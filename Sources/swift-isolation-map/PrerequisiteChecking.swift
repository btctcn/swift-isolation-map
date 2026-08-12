import Foundation
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration

/// Checked once, up front, before any real analysis work begins (file scanning, syntax
/// extraction, index-store discovery) -- every external tool/dylib this project depends on
/// (`xcrun`, `xcodebuild`/`swift`, the two `dlopen`'d toolchain dylibs) otherwise only surfaces a
/// failure deep inside the pipeline, sometimes after real work has already happened, and -- for
/// `LiveProcessRunner` specifically -- a genuinely missing executable never throws a Swift-level
/// error at all: it launches via `/usr/bin/env <executable>`, and `env` itself always exists, so
/// a missing target just comes back as a normal (non-throwing) `ProcessResult` with a nonzero
/// exit code and `env: <name>: No such file or directory` on stderr. Every check here handles
/// that shape explicitly rather than relying on `try?` to catch it.
///
/// Collects every failure, not just the first -- a user fixing a broken environment should see
/// the whole list in one pass, not one problem per re-run.
enum PrerequisiteChecking {
    static func check(
        container: ProjectContainer,
        processRunning: ProcessRunning,
        toolchainLocator: ToolchainLocating,
        sourceKitDLocator: SourceKitDLocating
    ) -> [String] {
        var failures: [String] = []

        // Both locators independently run the identical `xcrun --find swift` resolution step --
        // if `xcrun`/the active toolchain itself is the problem, both fail the same way. Report
        // it once, not twice, but still individually verify each of the two actual dylibs exists
        // (a toolchain can resolve fine via `xcrun` yet be missing just one of them).
        var sawXcrunFailure = false
        do {
            _ = try toolchainLocator.libIndexStorePath()
        } catch {
            failures.append(String(describing: error))
            if case ToolchainLocatingError.xcrunFailed = error { sawXcrunFailure = true }
        }
        do {
            _ = try sourceKitDLocator.sourcekitdInProcPath()
        } catch {
            if case SourceKitDLocatingError.xcrunFailed = error, sawXcrunFailure {
                // Same root cause as the failure already recorded above -- don't duplicate it.
            } else {
                failures.append(String(describing: error))
            }
        }

        switch container {
        case .xcodeproj, .xcworkspace:
            if let failure = checkExecutable(
                "xcodebuild", arguments: ["-version"], processRunning: processRunning,
                notFoundHint: "xcodebuild not found. Install Xcode from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`.",
                describeFailure: xcodebuildFailureMessage
            ) {
                failures.append(failure)
            }
        case .swiftPackage:
            if let failure = checkExecutable(
                "swift", arguments: ["--version"], processRunning: processRunning,
                notFoundHint: "swift not found. Install Xcode or the Swift toolchain from https://swift.org/install, and make sure it's on your PATH.",
                describeFailure: { exitCode, standardError in
                    "`swift --version` failed (exit \(exitCode)): \(standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            ) {
                failures.append(failure)
            }
        }

        return failures
    }

    /// Runs `executable arguments...` and classifies the outcome into exactly one of: succeeded
    /// (`nil`), not found at all (`env`'s own "No such file or directory" shape), or ran but
    /// failed for some other real reason (`describeFailure` renders that case's own message).
    private static func checkExecutable(
        _ executable: String, arguments: [String], processRunning: ProcessRunning,
        notFoundHint: String, describeFailure: (Int32, String) -> String
    ) -> String? {
        guard let result = try? processRunning.run(executable: executable, arguments: arguments, workingDirectory: nil) else {
            return notFoundHint
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 127, result.standardError.contains("\(executable): No such file or directory") {
                return notFoundHint
            }
            return describeFailure(result.exitCode, result.standardError)
        }
        return nil
    }

    /// Shared with `SwiftVersionDetectionError.description`'s own `xcodebuildFailed` case (kept
    /// as a free function, not a method on that type, since this check runs `xcodebuild -version`
    /// rather than that type's own `-showBuildSettings` invocation -- same failure shape,
    /// different command).
    private static func xcodebuildFailureMessage(exitCode: Int32, standardError: String) -> String {
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("requires Xcode") || trimmed.contains("command line tools instance") {
            return "xcodebuild requires a full Xcode install, but the active developer directory is Command Line Tools only. Run `sudo xcode-select -s /Applications/Xcode.app` (adjust the path if Xcode is installed elsewhere), then try again.\n\(trimmed)"
        }
        return "xcodebuild failed (exit \(exitCode)): \(trimmed)"
    }
}
