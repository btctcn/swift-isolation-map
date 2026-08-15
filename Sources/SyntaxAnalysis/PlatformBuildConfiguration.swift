import SwiftIfConfig
import SwiftSyntax

/// The single target platform this analysis run is for -- real projects (this tool's own included)
/// build for exactly one platform per invocation, never several at once, so a flat enum (not a
/// full target-triple model) is all `#if os(...)`/`canImport(...)` evaluation below needs.
public enum TargetPlatform: Sendable, Equatable {
    case iOS, macOS, tvOS, watchOS
    /// The platform couldn't be determined (a `CompilerArgumentsProviding` failure, an unsupported
    /// container, or a caller -- a test fixture, say -- that never had one to give). Every
    /// `PlatformBuildConfiguration` query below answers `true`/"active" for this case -- but that
    /// alone is *not* what makes extraction platform-blind for `.unknown` (a `#if`/`#elseif` chain
    /// only ever has one active clause, so answering every query `true` would just make the
    /// textually-first clause win, silently dropping a real declaration written in a later one).
    /// The actual preservation of this project's pre-fix "extract every branch unconditionally"
    /// behavior for this case is `PlatformAwareSyntaxVisitor`'s own job -- see its doc comment.
    case unknown
}

/// Real root cause (docs/task-bulk-extraction-wrong-platform.md §5): `SyntaxAnalysis`'s own
/// declaration/call-graph/closure/await extraction walked a plain `SwiftSyntax` tree, which has
/// *no* `#if` evaluation at all -- every clause of every `#if os(iOS) ... #elseif os(OSX) ...
/// #endif` is ordinary syntax to a bare `SyntaxVisitor`, so a real, dead-for-this-platform branch
/// (Cartography's own `LayoutGuide.swift:36`, inside `#elseif os(OSX)`) was extracted exactly like
/// live code, generating a phantom oracle work item that `sourcekitd` then answered by genuinely
/// attempting to build that branch against the real (iOS) SDK -- reproduced, minimally and
/// deterministically, as a single fresh `cursorinfo` query at that exact position.
///
/// This conforms to `SwiftIfConfig.BuildConfiguration` so every extractor's own `SyntaxVisitor`
/// subclass can become an `ActiveSyntaxVisitor` instead (`SwiftIfConfig`'s own type for "walk only
/// the syntax that would really be compiled") -- a pure *visitor* change, never a tree rewrite:
/// `ActiveSyntaxVisitor` still walks the original, unmodified tree, just skipping inactive `#if`
/// clauses' children, so every existing `SourceLocationConverter`-derived line/column stays exactly
/// as before for every node this project's own extractors still visit. (`SyntaxProtocol.
/// removingInactive(in:)` was considered and rejected for this reason: it's a real `SyntaxRewriter`
/// that excises inactive regions from the tree, which would shift every downstream declaration's
/// line/column relative to the real file on disk.)
///
/// Deliberately narrow beyond `os(...)`/`canImport(...)`: every other `BuildConfiguration` query
/// below answers permissively (`true`, "assume active") rather than attempting a fully faithful
/// re-implementation of the real compiler's build-configuration evaluation. Two concrete reasons,
/// not just caution for its own sake:
/// - This project's own real corpus builds *multiple* architectures for one destination (a generic
///   `iOS Simulator` destination produces both `arm64` and `x86_64` `swiftc` invocations for the
///   same target -- confirmed directly against `Cartography`'s own real captured build log) --
///   answering `isActiveTargetArchitecture` for one specific architecture would incorrectly treat
///   the *other*, equally real architecture's own `#if arch(...)`-guarded code as dead.
/// - `os(...)`/`canImport(...)` are the two mechanisms this investigation's own real corpus (four
///   independent third-party dependencies: Cartography, Kingfisher, SwiftRichString, PromiseKit)
///   was confirmed to actually hit; the remaining `BuildConfiguration` axes (custom `-D` flags,
///   language/compiler version checks, target environment, runtime, pointer authentication, object
///   format) are real but unconfirmed here, and answering them wrong risks trading one class of
///   false negative (a phantom declaration, this fix's whole point) for a different one (a real
///   declaration silently dropped because this project guessed a flag/version wrong).
public struct PlatformBuildConfiguration: BuildConfiguration, Sendable {
    public let platform: TargetPlatform

    public init(platform: TargetPlatform) {
        self.platform = platform
    }

    /// Real `#if os(...)` name aliases -- confirmed against a real third-party source
    /// (`Cartography/LayoutGuide.swift`, this fix's own motivating file): `OSX` is still real,
    /// live, in-use syntax for what `canImport`/target-triple data calls `macOS`, not a typo or a
    /// hypothetical legacy form.
    private static let osAliases: [TargetPlatform: Set<String>] = [
        .iOS: ["iOS"],
        .macOS: ["macOS", "OSX"],
        .tvOS: ["tvOS"],
        .watchOS: ["watchOS"]
    ]

    public func isActiveTargetOS(name: String) throws -> Bool {
        guard platform != .unknown else { return true }
        guard let aliases = Self.osAliases[platform] else { return true }
        return aliases.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Confirmed platform-exclusive framework names, mapped to exactly which platform(s) each is
    /// real, live SDK availability for -- deliberately small and specific (the modules this
    /// investigation's real corpus actually referenced, across all three of its confirmed offending
    /// dependencies: Cartography's `AppKit`, Kingfisher's `AppKit`/`WatchKit`/`TVUIKit`), not a
    /// guessed exhaustive SDK catalog. Any module name absent from this table answers `true`
    /// ("assume importable") -- the safe default for the overwhelming majority of real
    /// `canImport(...)` guards, which name a genuinely cross-platform or first-party project module
    /// this table has no business claiming to know about.
    ///
    /// **Not** a coarse "macOS-only vs. everything-else" split -- confirmed the hard way, against
    /// this exact real corpus: `WatchKit` and `UIKit` do *not* share one bucket (`Kingfisher`'s own
    /// `HasImageComponent+Kingfisher.swift` has three independent, non-`#elseif`-chained blocks --
    /// `#if canImport(AppKit) ... #endif`, `#if canImport(UIKit) && !os(watchOS) ... #endif`, `#if
    /// canImport(WatchKit) ... #endif` -- an initial version of this table that put `WatchKit`
    /// alongside `UIKit` in one "iOS-family" set answered `canImport(WatchKit)` as `true` on iOS,
    /// still producing the real `no such module 'WatchKit'` error this whole investigation traced).
    private static let platformExclusiveModules: [String: Set<TargetPlatform>] = [
        "AppKit": [.macOS],
        "Cocoa": [.macOS],
        "IOKit": [.macOS],
        "CoreWLAN": [.macOS],
        "ScriptingBridge": [.macOS],
        "PreferencePanes": [.macOS],
        "InstallerPlugins": [.macOS],
        "UIKit": [.iOS, .tvOS],
        "WatchKit": [.watchOS],
        "TVUIKit": [.tvOS]
    ]

    public func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        guard platform != .unknown, let moduleName = importPath.first?.1 else { return true }
        guard let availableOn = Self.platformExclusiveModules[moduleName] else { return true }
        return availableOn.contains(platform)
    }

    // MARK: - Deliberately permissive (see this type's own doc comment)

    public func isCustomConditionSet(name: String) throws -> Bool { true }
    public func hasFeature(name: String) throws -> Bool { true }
    public func hasAttribute(name: String) throws -> Bool { true }
    public func isActiveTargetArchitecture(name: String) throws -> Bool { true }
    public func isActiveTargetEnvironment(name: String) throws -> Bool { true }
    public func isActiveTargetRuntime(name: String) throws -> Bool { true }
    public func isActiveTargetPointerAuthentication(name: String) throws -> Bool { true }
    public func isActiveTargetObjectFormat(name: String) throws -> Bool { true }
    public var targetPointerBitWidth: Int { 64 }
    public var targetAtomicBitWidths: [Int] { [8, 16, 32, 64] }
    public var endianness: Endianness { .little }
    /// A generously high, real-toolchain-plausible default -- permissive in the same spirit as the
    /// axes above: a `#if swift(>=X)`/`#if compiler(>=X)` guard almost always exists to gate a
    /// *newer* feature the source wants to use *if available*, so treating "is this version
    /// available" as usually-true keeps that code active rather than silently dropping it.
    public var languageVersion: VersionTuple { VersionTuple(6, 0) }
    public var compilerVersion: VersionTuple { VersionTuple(6, 0) }
}

/// Every `SyntaxAnalysis` extractor's own visitor base class -- behaves exactly like
/// `ActiveSyntaxVisitor` (only visits nodes active for `configuration`) when the platform is known,
/// and exactly like a plain, pre-fix `SyntaxVisitor` (visits *every* `#if`/`#elseif`/`#else` clause
/// unconditionally, never skipping any) when `configuration.platform == .unknown`.
///
/// This distinction is real, not cosmetic -- caught by review, not by any test this fix originally
/// shipped with (docs/task-bulk-extraction-wrong-platform.md §5's own decision record): `#if`/
/// `#elseif` chains only ever have *one* active clause by construction (real Swift language
/// semantics `SwiftIfConfig` correctly mirrors), so simply answering every `BuildConfiguration`
/// query `true` for `.unknown` does **not** mean "every branch survives" -- it means "the
/// textually-first branch always wins," because that's the first one `ActiveClauseEvaluator` finds
/// with a true condition. For a file whose *real* branch (for whatever platform this analysis run
/// actually targets, undetected here) happens to be written *second* (an `#elseif`, not the leading
/// `#if`), that would silently extract the wrong branch and drop the real declaration entirely --
/// the exact failure mode this whole fix exists to prevent, just inverted (a wrong/missing
/// declaration instead of a duplicated phantom one). Missing a real declaration is strictly worse
/// than this project's own pre-fix status quo (an extra phantom one, tolerated everywhere
/// downstream via this project's own fail-soft "unknown, not silently wrong" oracle contract), so
/// `.unknown` deliberately reproduces that old, platform-blind "visit everything" behavior exactly,
/// rather than approximating it.
class PlatformAwareSyntaxVisitor: ActiveSyntaxVisitor {
    private let isPlatformKnown: Bool

    init(viewMode: SyntaxTreeViewMode, configuration: PlatformBuildConfiguration) {
        self.isPlatformKnown = configuration.platform != .unknown
        super.init(viewMode: viewMode, configuration: configuration)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isPlatformKnown else { return .visitChildren }
        return super.visit(node)
    }
}
