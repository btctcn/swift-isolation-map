import Foundation

/// Pure parsing of real `xcodebuild -showBuildSettings ...` output -- a fast, **read-only** call
/// that triggers no build at all (confirmed empirically against a real, large project: completes
/// in seconds regardless of whether the project is up to date), unlike `-verbose build`
/// (`XcodeBuildLogCompilerArgumentsProvider`'s slow path, only needed for the live per-file
/// cursor-info fallback). Used to derive the SDK path, target triple, and framework search paths
/// for bulk `symbolgraph-extract` calls without ever running a real build.
enum XcodeBuildSettingsParser {
    /// Each real line has the shape `    KEY = VALUE` (four-space indent, space-equals-space
    /// separator, confirmed against real captured `Project Iris` output). A key can appear once per
    /// "Build settings for action build and target X:" block; a scheme can resolve to more than
    /// one target in principle, but the primary target's block was empirically the *only* one
    /// printed for a real app scheme this session -- the *first* occurrence of a key is kept
    /// (the primary target's own settings), not the last, in case a future multi-target scheme
    /// ever does print more than one block.
    static func parse(output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separatorRange = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separatorRange.lowerBound])
            guard !key.isEmpty, key.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { continue }
            guard result[key] == nil else { continue }
            result[key] = String(trimmed[separatorRange.upperBound...])
        }
        return result
    }

    /// Real Swift target-triple OS-component spellings, confirmed empirically this session to
    /// differ from the SDK/platform-name spelling `-showBuildSettings` itself uses: a real captured
    /// `~/SQLumen` compile line used `-target arm64-apple-macos26.4` (not "macosx", despite
    /// `SDKROOT`/`SDK_NAME` saying "macosx"/"MacOSX...sdk"); separately, `swift symbolgraph-extract
    /// -target arm64-apple-iphoneos15.6` was confirmed this session to silently produce garbage
    /// (an unrelated Clang-module dump), while `-target arm64-apple-ios15.6` against the identical
    /// SDK correctly extracted `Swift`'s own real symbol graph -- "ios", not "iphoneos", is the only
    /// spelling confirmed to actually work. The simulator/tvOS/watchOS entries follow the same
    /// documented Apple platform-triple convention but were not independently re-verified this
    /// session (this project's two real validation targets, `Project Iris`/`~/SQLumen`, are device/macOS
    /// only) -- spot-check before trusting if a simulator/tvOS/watchOS project is ever exercised.
    private static let platformTripleComponents: [String: (os: String, isSimulator: Bool)] = [
        "macosx": ("macos", false),
        "iphoneos": ("ios", false),
        "iphonesimulator": ("ios", true),
        "appletvos": ("tvos", false),
        "appletvsimulator": ("tvos", true),
        "watchos": ("watchos", false),
        "watchsimulator": ("watchos", true)
    ]

    /// Builds a real Swift target triple (`<arch>-apple-<os><deploymentTarget>[-simulator]`) from
    /// build settings already extracted by `parse(output:)`. Returns `nil` for any platform not in
    /// the table above rather than guessing -- an unrecognized platform must fall through to the
    /// live per-file oracle path, never a fabricated triple.
    static func targetTriple(architecture: String, platformName: String, deploymentTarget: String) -> String? {
        guard let (os, isSimulator) = platformTripleComponents[platformName] else { return nil }
        let suffix = isSimulator ? "-simulator" : ""
        return "\(architecture)-apple-\(os)\(deploymentTarget)\(suffix)"
    }
}
