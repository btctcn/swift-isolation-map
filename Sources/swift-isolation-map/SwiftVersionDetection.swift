import Foundation
import ProjectResolution

enum SwiftVersionDetectionError: Error, Equatable, CustomStringConvertible {
    case xcodebuildFailed(exitCode: Int32, standardError: String)
    case swiftVersionSettingNotFound
    case swiftVersionCommandFailed(exitCode: Int32, standardError: String)
    case unrecognizedCompilerVersionOutput(String)

    public var description: String {
        switch self {
        case .xcodebuildFailed(let exitCode, let standardError):
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            // The single most common real-world cause of this specific failure: `xcode-select`
            // points at the Command Line Tools only, not a full Xcode install -- `xcodebuild`
            // exists and runs, but refuses every real command with this exact message. Worth its
            // own remediation hint since the raw message alone doesn't say what to *do* about it.
            if trimmed.contains("requires Xcode") || trimmed.contains("command line tools instance") {
                return "xcodebuild requires a full Xcode install, but the active developer directory is Command Line Tools only. Run `sudo xcode-select -s /Applications/Xcode.app` (adjust the path if Xcode is installed elsewhere), then try again.\n\(trimmed)"
            }
            return "xcodebuild failed (exit \(exitCode)): \(trimmed)"
        case .swiftVersionSettingNotFound:
            return "Could not find a SWIFT_VERSION build setting in `xcodebuild -showBuildSettings`'s output."
        case .swiftVersionCommandFailed(let exitCode, let standardError):
            return "`swift --version` failed (exit \(exitCode)): \(standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .unrecognizedCompilerVersionOutput(let output):
            return "Could not parse a Swift version out of `swift --version`'s output:\n\(output)"
        }
    }
}

/// Two independent axes, not one -- verified empirically against a real project (SQLumen) before
/// this was written, not assumed from the architecture doc's sketch. `swift package describe`'s
/// `tools_version` / `xcodebuild -showBuildSettings`'s `SWIFT_VERSION` is the project's
/// **language mode** (a build setting a project pins independently of which compiler builds it --
/// that decoupling is the entire point of Swift 6's opt-in migration). Neither setting says which
/// **compiler/toolchain** is actually doing the compiling (confirmed: SQLumen reports
/// `SWIFT_VERSION = 5.0` while being built by a Swift 6.3 toolchain) -- that only comes from the
/// active toolchain itself (`swift --version`).
enum SwiftVersionDetection {
    /// SPM's language mode is already available as `SPMResolvedScheme.toolsVersion` (threaded
    /// through from `swift package describe`'s `tools_version` field) -- no subprocess call
    /// needed here. Xcode has no equivalent already-resolved field (this project deliberately
    /// never hand-parses `.pbxproj`/`.xcscheme` files for build settings, per the architecture
    /// spec's own warning), so it's queried live via `xcodebuild -showBuildSettings`.
    static func xcodeLanguageMode(
        container: ProjectContainer,
        schemeName: String,
        processRunning: ProcessRunning
    ) throws -> String {
        var arguments = ["-showBuildSettings", "-scheme", schemeName]
        switch container {
        case .xcodeproj(let url):
            arguments += ["-project", url.path]
        case .xcworkspace(let url):
            arguments += ["-workspace", url.path]
        case .swiftPackage:
            preconditionFailure("xcodeLanguageMode is only valid for .xcodeproj/.xcworkspace containers")
        }
        let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw SwiftVersionDetectionError.xcodebuildFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        // Exact-key match on the trimmed line, not `contains`/`hasSuffix` -- real
        // `-showBuildSettings` output also has an `EFFECTIVE_SWIFT_VERSION` line, which contains
        // "SWIFT_VERSION" as a substring and would false-positive-match a looser check (confirmed
        // both keys appear together against a real project).
        for line in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SWIFT_VERSION ") || trimmed.hasPrefix("SWIFT_VERSION=") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[1].isEmpty {
                return parts[1]
            }
        }
        throw SwiftVersionDetectionError.swiftVersionSettingNotFound
    }

    /// Output format confirmed empirically (`swift --version`, real toolchain): the version
    /// itself is on stdout (`Apple Swift version 6.3 (swiftlang-6.3.0.123.5 ...)`); the
    /// `swift-driver version: ...` line is on stderr. Both streams are searched anyway so this
    /// doesn't depend on that split holding across every toolchain distribution.
    static func compilerVersion(processRunning: ProcessRunning) throws -> String {
        let result = try processRunning.run(executable: "swift", arguments: ["--version"], workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw SwiftVersionDetectionError.swiftVersionCommandFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        let combined = result.standardOutput + "\n" + result.standardError
        guard let match = combined.range(of: #"Swift version (\d+(?:\.\d+)?)"#, options: .regularExpression) else {
            throw SwiftVersionDetectionError.unrecognizedCompilerVersionOutput(combined)
        }
        let matchedText = String(combined[match])
        guard let versionRange = matchedText.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else {
            throw SwiftVersionDetectionError.unrecognizedCompilerVersionOutput(combined)
        }
        return String(matchedText[versionRange])
    }

    /// Language mode major < 6 always means `Swift5RuleSet`, regardless of which compiler
    /// actually built the project -- that decoupling is the entire point of Swift 6's opt-in
    /// migration (a Swift-5-mode project built by a Swift 6.3 toolchain is still analyzed under
    /// Swift 5 rules, since the compiler enforces Swift 5 concurrency checking for it). Only once
    /// the language mode has itself opted into Swift 6 does the *compiler* version decide which
    /// `Swift6xRuleSet` applies (SE-0466 only exists from 6.2 on, etc.).
    static func effectiveVersion(languageMode: String, compilerVersion: String) -> String {
        let major = languageMode.split(separator: ".").first.flatMap { Int($0) } ?? 0
        return major < 6 ? languageMode : compilerVersion
    }
}
