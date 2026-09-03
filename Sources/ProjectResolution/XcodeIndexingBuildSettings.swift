import Foundation

/// The bare `KEY=VALUE` build-setting overrides every real `xcodebuild ... build` invocation this
/// project makes needs (`SwiftIsolationMap.build`).
///
/// - `COMPILER_INDEX_STORE_ENABLE=YES`: turns on indexing-while-building (confirmed empirically --
///   there is no `-indexStoreEnable` flag; `xcodebuild -indexStoreEnable YES` fails with "invalid
///   option" against a real project, Xcode 26.4.0).
/// - `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO`: without an explicit `-destination`, a
///   scheme with real signed targets (an app plus any extension) resolves to a real-device
///   destination requiring a provisioning profile -- confirmed against a real, independent project
///   (`WordPress-iOS`'s `WordPress` scheme, 4 signed targets): every invocation failed immediately
///   with `error: No profile for team '...' matching '...' found`, before a single compile line was
///   ever printed. Neither call site needs a signed, runnable binary -- one only needs the index
///   store populated, the other only needs the compiler invocation lines from the build log -- so
///   disabling signing outright sidesteps that particular failure. It does **not**, on its own,
///   make the destination choice safe -- see `resolveDeterministicSimulatorDestination` below.
public let xcodeIndexingBuildSettings = [
    "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
]

/// Thrown when `--platform` names a platform this scheme's own real `-showdestinations` output
/// simply doesn't offer a Simulator destination for -- confirmed real (issue #140): a modern
/// multiplatform SwiftUI scheme (`IceCubesApp`) lists several genuinely simultaneous Simulator
/// platforms for one scheme (`iOS Simulator`, `visionOS Simulator`), and picking the wrong one
/// silently, the way `resolveDeterministicSimulatorDestination` always did before `--platform`
/// existed, is exactly the kind of surprise this project's own guiding principle exists to prevent.
/// A request naming a platform this scheme can't offer must fail loudly, not fall back to some
/// other platform the user didn't ask for.
public enum DestinationResolutionError: Error, CustomStringConvertible, Equatable {
    case requestedPlatformNotAvailable(requested: String, available: [String])

    public var description: String {
        switch self {
        case .requestedPlatformNotAvailable(let requested, let available):
            let availableList = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "--platform \(requested) is not a valid Simulator destination for this scheme. Available: \(availableList)."
        }
    }
}

/// Picks a deterministic Simulator destination for schemes that have one, so `xcodebuild`'s own
/// destination auto-selection -- which silently picks whichever destination `-showdestinations`
/// happens to list *first* -- never decides which SDK a build (and everything downstream: every
/// live sourcekitd query run against its compiler arguments) actually targets.
///
/// Confirmed against a real host analyzing a real project (`Swiftfin`): a physical iPhone paired
/// to the machine at some point in the past but not currently connected (`ab iphone x`) sorted
/// ahead of every Simulator destination in `-showdestinations`. With no `-destination` passed,
/// `xcodebuild build` silently built for `Debug-iphoneos` instead of `Debug-iphonesimulator` --
/// compiling successfully (`CODE_SIGNING_ALLOWED=NO` already sidesteps the provisioning-profile
/// failure above) but producing compiler arguments sourcekitd could not construct a working
/// `ASTInvocation` from, collapsing live-fallback resolution from ~1300 real declarations to
/// zero. Which physical device (if any) happens to sort first is a fact about the host machine's
/// pairing history, not the project -- so this failure mode is nondeterministic across
/// environments and across time on the very same machine, exactly the shape that made it invisible
/// during this project's own earlier verification runs.
///
/// Returns `nil` (no override, today's exact prior behavior) for a scheme with no Simulator-
/// capable platform at all (a pure macOS/host scheme) -- there, `xcodebuild`'s default destination
/// is already the unambiguous host Mac, and forcing a `-destination` would only add a new way to
/// fail against a project this function has no evidence is broken for.
/// `derivedDataPath` -- confirmed necessary, not just tidy: even a read-only-seeming
/// `-showdestinations` query resolves the real package graph (real `xcodebuild`, real Xcode
/// project), and for a project with SPM macro/build-tool plugins that means actually *compiling*
/// those plugin binaries -- confirmed directly against two independent real projects
/// (`WordPress-iOS`, `Swiftfin`) that both left a real, populated
/// `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>` folder behind from this call alone,
/// every single run, even after every *other* real `xcodebuild` invocation in this project had
/// already been routed through its own private path. `nil` is accepted (not a required parameter)
/// for the one real caller that cannot know its own private path yet -- the private path's own
/// composite key includes this function's own return value, so the very first bootstrap call has
/// nothing to pass; that caller uses `PrivateDerivedData.path(destination: nil)` instead (a real,
/// private, still-never-shared location, just keyed on a fixed placeholder segment rather than the
/// real destination) -- see `SwiftIsolationMap.swift`'s own call site for why.
/// `preferredPlatform` (issue #140, the `--platform` CLI flag): when a scheme's own real
/// destinations include more than one simultaneously-valid Simulator platform (a modern
/// multiplatform SwiftUI target adding visionOS as an *additional destination on the same scheme*,
/// not a separate one -- confirmed real on `IceCubesApp`), the old unconditional "first Simulator
/// line wins" behavior could never reach any platform but whichever `xcodebuild` happened to list
/// first. `nil` (every existing caller before `--platform` existed) preserves that exact original
/// behavior. A non-`nil` value matches case-insensitively, by substring, against each real
/// candidate's own platform string (`"visionOS"` matches `"visionOS Simulator"`) -- and throws
/// `DestinationResolutionError` rather than silently falling back to a platform the user didn't
/// request, when the scheme genuinely doesn't offer a Simulator destination for that name at all.
public func resolveDeterministicSimulatorDestination(
    container: ProjectContainer, scheme: String, processRunning: ProcessRunning, derivedDataPath: URL? = nil,
    preferredPlatform: String? = nil
) throws -> String? {
    var arguments = ["-showdestinations", "-scheme", scheme]
    switch container {
    case .xcodeproj(let url): arguments += ["-project", url.path]
    case .xcworkspace(let url): arguments += ["-workspace", url.path]
    case .swiftPackage: return nil
    }
    if let derivedDataPath {
        arguments += ["-derivedDataPath", derivedDataPath.path]
    }
    guard let result = try? processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil) else {
        return nil
    }
    var simulatorPlatforms: [Substring] = []
    for line in result.standardOutput.split(separator: "\n") {
        guard let platformRange = line.range(of: "platform:") else { continue }
        let platform = line[platformRange.upperBound...].prefix { $0 != "," && $0 != "}" }
        if platform.contains("Simulator") {
            simulatorPlatforms.append(platform)
        }
    }
    guard let preferredPlatform else {
        guard let first = simulatorPlatforms.first else { return nil }
        return "generic/platform=\(first)"
    }
    guard let matched = simulatorPlatforms.first(where: { $0.localizedCaseInsensitiveContains(preferredPlatform) }) else {
        throw DestinationResolutionError.requestedPlatformNotAvailable(
            requested: preferredPlatform, available: simulatorPlatforms.map(String.init)
        )
    }
    return "generic/platform=\(matched)"
}
