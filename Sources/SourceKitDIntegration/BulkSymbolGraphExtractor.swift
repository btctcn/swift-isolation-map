import Foundation
import IsolationCore
import ProjectResolution

/// Bulk-resolves isolation for every public symbol in a whole SDK module at once, via
/// `swift symbolgraph-extract -module-name <X> -sdk ... -target ...` -- the same real compiler
/// data source `SymbolGraphIsolationParser` already parses per-symbol from `cursorinfo`
/// (`SymbolGraphGen`, shared by both paths), just retrieved for an entire module in one process
/// invocation instead of one `sourcekitd` round trip per external declaration. Empirically
/// confirmed: extracting all of UIKit (~26MB JSON, thousands of symbols, including `UIViewController`
/// correctly carrying `@MainActor` in its `declarationFragments`) takes a few seconds on the real
/// toolchain -- versus the hundreds of individual live `cursorinfo` queries a large real project
/// needed before this existed (see docs/priority-3-compiled-dependency-isolation.md for the
/// `Project Iris` before/after timing).
///
/// This is a *performance* cache, not a new source of truth: every value still comes from the real
/// compiler, keyed by real USR (`identifier.precise`, module-qualified and unambiguous by
/// construction -- never a bare name). A module not covered here (a custom XCFramework, a
/// third-party binary SwiftPM dependency, or any SDK module simply not in `moduleNames`) is absent
/// from the returned dictionary, and callers fall back to the existing live per-declaration
/// `cursorinfo` oracle, unaffected and unchanged.
/// `isolationByUSR` is the existing, unchanged contract (every resolved external symbol's own
/// isolation, keyed by USR). `protocolUSRs` is additional: the subset of those USRs whose
/// `symbolgraph-extract`-reported `kind.identifier` is `"swift.protocol"` -- needed to tell a
/// genuine protocol conformance apart from a class-bound protocol's inheritance-clause entry
/// (`protocol P: UIView`), which names a *class*, not a protocol. Both share the same
/// `conformedProtocolNames`/`ProtocolConformance.protocolUSR` representation upstream (`SyntaxAnalysis
/// .DeclarationExtractor` has no project-wide type-kind knowledge at extraction time to split them),
/// so only here -- where the real, authoritative kind first becomes available -- can the two be
/// told apart. See `ExternalIsolationBackfill`'s own use of `protocolUSRs` for why the distinction
/// matters: SE-0316's "conformance to a global-actor-qualified protocol" rule applies only when the
/// conformed-to name is itself a protocol annotated with a global actor -- never when it's a class
/// that merely happens to be global-actor-isolated via its own hierarchy.
public struct BulkSymbolGraphResolution: Sendable {
    public let isolationByUSR: [String: IsolationKind]
    public let protocolUSRs: Set<String>
    /// Issue #40: bare names of every type this extraction found declared with a literal
    /// `@globalActor` attribute on its *own* declaration -- confirmed directly against real
    /// compiler output (`swift symbolgraph-extract`) that this is an unambiguous, single-fragment
    /// signal (`{"kind":"attribute","spelling":"@globalActor"}`), distinct from the name-matching
    /// heuristic `GlobalActorNameValidation` needs elsewhere: a type's *own* declaration either
    /// carries this literal compiler keyword or it doesn't, no property-wrapper/result-builder
    /// confusability possible (that ambiguity only exists for an attribute *usage* site, which
    /// only ever has a fragment naming the referenced type, never a copy of that type's own
    /// declaration). Meant to be unioned into `knownGlobalActorNames` upstream (`DeclarationLinker
    /// .link`'s `additionalGlobalActorNames`) so a real global actor declared in a compiled
    /// dependency -- invisible to this project's own syntactic scan by construction -- still
    /// enters the accept-list `ClosureIsolationExtractor.classify`/`GlobalActorNameValidation`
    /// both already trust, rather than needing a second, separate validation mechanism.
    public let discoveredGlobalActorNames: Set<String>
    /// The module every `isolationByUSR` entry came from, keyed identically -- trivially known by
    /// construction (`extractAll`'s own per-`job.name` merge loop, never parsed out of a response;
    /// one whole-module `symbolgraph-extract` invocation only ever produces symbols belonging to
    /// the module it was asked to extract). Needed by the `@preconcurrency import` severity-
    /// downgrade trigger (docs/task-escape-hatch-and-preconcurrency-severity.md, PR2) -- without
    /// this, that trigger could never fire for any bulk-cache-resolved declaration, which real-corpus
    /// measurement showed is the *majority* case on some real corpora (e.g. Kingfisher, Auth0.swift),
    /// not a rare edge case. A separate field from `isolationByUSR` (not folded into a combined
    /// value type there) deliberately -- `isolationByUSR` is an already-established, heavily-tested
    /// public contract (`BulkSymbolGraphExtractorTests`'s direct `== .globalActor(...)` assertions);
    /// changing its value type would break that contract for a fact only a minority of its own
    /// consumers need.
    public let moduleNameByUSR: [String: String]

    public init(
        isolationByUSR: [String: IsolationKind], protocolUSRs: Set<String>, discoveredGlobalActorNames: Set<String> = [],
        moduleNameByUSR: [String: String] = [:]
    ) {
        self.isolationByUSR = isolationByUSR
        self.protocolUSRs = protocolUSRs
        self.discoveredGlobalActorNames = discoveredGlobalActorNames
        self.moduleNameByUSR = moduleNameByUSR
    }
}

public enum BulkSymbolGraphExtractor {
    /// Well-known SDK modules worth eagerly bulk-extracting -- covers the overwhelming majority of
    /// external superclasses/protocols/call targets real iOS/macOS projects reference. Deliberately
    /// *not* a source-of-truth list -- it only controls which modules get this fast path; a project
    /// referencing something outside this list still resolves correctly, just via the slower
    /// live-query path this list exists to avoid for the common case.
    ///
    /// `Foundation`/`ObjectiveC`/`CoreGraphics`/`Dispatch` were added after real-world validation
    /// against `Project Iris` showed the original three-module list (`UIKit`/`AppKit`/`SwiftUI`) alone left
    /// a large residual live-query volume -- these SDK modules aren't discoverable the way
    /// third-party CocoaPods/XCFrameworks are (`FrameworkModuleDiscovery`, not separate
    /// `-F`-searchable directories, implicitly available via `-sdk` alone the same way UIKit is),
    /// so they must be requested explicitly. Confirmed empirically each extracts in well under 5
    /// seconds (`Foundation` itself, the largest of that batch, ~4.7s) -- cheap enough to always
    /// attempt. `Swift`/`CoreFoundation` were added after the same diagnostic identified real,
    /// uncovered residual misses shaped like bare stdlib symbols (`Array`'s literal initializer,
    /// `Bool`'s `!` operator, `CGFloat` literal inits) -- despite `Swift` being, per real-world
    /// research, plausibly "the largest module there is," measured empirically at ~1.2s/51MB here
    /// (`CoreFoundation`: ~0.5s/5MB) -- not assumed cheap just because every other module was.
    public static let defaultModules = ["UIKit", "AppKit", "SwiftUI", "Foundation", "ObjectiveC", "CoreGraphics", "Dispatch", "Swift", "CoreFoundation"]

    /// A hung or pathologically slow module (a large/misconfigured third-party framework) must
    /// not be able to stall the whole bulk phase indefinitely -- bounded, but generous. The
    /// original 60s (4x the ~14s `AppKit` extraction measured on an 8-core dev machine) was proven
    /// too tight this session: a real `macos-latest` CI run's weaker hardware reproducibly (3 of 3
    /// consecutive runs) hit this exact timeout extracting `AppKit`, silently returning an empty
    /// result (`extract()`'s own documented fail-soft behavior on a non-zero exit) and failing
    /// `BulkSymbolGraphExtractorTests`'s live-toolchain assertion -- not a hang, just genuinely
    /// slower hardware needing more than 60s for the same real work. Raised with a much larger
    /// margin so a slower CI runner (or a heavier module than AppKit) doesn't hit this again.
    static let perModuleTimeout: TimeInterval = 300

    /// Extracts and merges every module in `moduleNames` (well-known SDK modules, `-sdk`/`-target`
    /// only) plus every `discoveredModules` entry (real third-party modules found in the project's
    /// own build configuration, each with its own `extractionFlags`, e.g. `-F <path>`), silently
    /// skipping (not failing) any module absent from the current SDK or otherwise unresolvable --
    /// e.g. requesting `AppKit` against an iOS SDK, which `symbolgraph-extract` itself rejects with
    /// a non-zero exit, or a module that times out. Fail-soft end to end, matching the rest of the
    /// external-isolation oracle's contract: a module this can't cover just means its symbols fall
    /// through to the live query path, never a crash or a wrong answer.
    ///
    /// Runs every module's extraction concurrently via `DispatchQueue.concurrentPerform` -- real OS
    /// threads, not Swift's cooperative pool (this is a plain synchronous function with no actor
    /// isolation to preserve, and the rest of this codebase already avoids blocking the cooperative
    /// pool with synchronous subprocess waits the same way, via `runAsyncBridge`'s hand-rolled
    /// semaphore). Each iteration writes to its own preallocated array slot (never a shared
    /// dictionary mutated from parallel closures), then results are merged back in the original,
    /// deterministic module order afterward, regardless of completion order.
    public static func extractAll(
        moduleNames: [String] = defaultModules,
        discoveredModules: [DiscoveredModule] = [],
        sdkPath: String,
        target: String,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying
    ) -> BulkSymbolGraphResolution {
        let jobs: [(name: String, extractionFlags: [String])] =
            moduleNames.map { (name: $0, extractionFlags: []) }
            + discoveredModules.map { (name: $0.name, extractionFlags: $0.extractionFlags) }
        guard !jobs.isEmpty else { return BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: []) }

        let resultBuffer = ResultBuffer(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            let extracted = extract(
                moduleName: job.name, sdkPath: sdkPath, target: target, additionalArguments: job.extractionFlags,
                processRunning: processRunning, fileSystem: fileSystem
            )
            resultBuffer.set(extracted, at: index)
        }

        var merged: [String: IsolationKind] = [:]
        var mergedModuleNames: [String: String] = [:]
        var mergedProtocolUSRs: Set<String> = []
        var mergedGlobalActorNames: Set<String> = []
        for (index, result) in resultBuffer.results.enumerated() {
            let moduleName = jobs[index].name
            for (usr, isolation) in result.isolationByUSR {
                merged[usr] = isolation
                mergedModuleNames[usr] = moduleName
            }
            mergedProtocolUSRs.formUnion(result.protocolUSRs)
            mergedGlobalActorNames.formUnion(result.discoveredGlobalActorNames)
        }
        return BulkSymbolGraphResolution(
            isolationByUSR: merged, protocolUSRs: mergedProtocolUSRs, discoveredGlobalActorNames: mergedGlobalActorNames,
            moduleNameByUSR: mergedModuleNames
        )
    }

    static func extract(
        moduleName: String,
        sdkPath: String,
        target: String,
        additionalArguments: [String] = [],
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying
    ) -> BulkSymbolGraphResolution {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-isolation-map-symbolgraph-\(moduleName)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let result = try processRunning.run(
                executable: "xcrun",
                arguments: [
                    "swift", "symbolgraph-extract",
                    "-module-name", moduleName,
                    "-sdk", sdkPath,
                    "-target", target,
                    "-output-dir", outputDirectory.path,
                    "-minimum-access-level", "public"
                ] + additionalArguments,
                workingDirectory: nil,
                timeout: perModuleTimeout
            )
            guard result.exitCode == 0 else { return BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: []) }

            // Every `*.symbols.json` file, not just the module's own primary `<Module>.symbols.json`
            // -- confirmed empirically (a real two-module build: a `@MainActor` property added to
            // one module's type via `extension` from another module) that a symbol declared in an
            // extension of a type from a *different* module is serialized only into the sibling
            // `<Module>@<ExtendedModule>.symbols.json` file, never into the primary one, which is
            // left empty for that symbol. This is exactly the shape of the original motivating bug
            // (a Kingfisher extension member on `UITableViewCell`) -- reading only the primary file
            // would silently miss it. USR keys are globally unique regardless of which file they
            // came from, so merging needs no precedence logic.
            let symbolFiles = try fileSystem.contentsOfDirectory(at: outputDirectory)
                .filter { $0.lastPathComponent.hasSuffix(".symbols.json") }

            // Two passes, because a symbol's own fragments and the `memberOf`/`inheritsFrom`
            // relationships that place it in a type hierarchy can legitimately live in different
            // sibling files (the same cross-file split already documented above for symbols
            // themselves) -- the classification below needs all three, gathered project-wide,
            // before deciding any one USR's fate.
            var fragmentsByUSR: [String: [SymbolGraphDocument.Symbol.Fragment]] = [:]
            var containerOfMember: [String: String] = [:]
            var superclassOfType: [String: String] = [:]
            var protocolUSRs: Set<String> = []
            // Issue #40: a type's *own* declaration fragments carry a literal, single-fragment
            // `{"kind":"attribute","spelling":"@globalActor"}` when it's declared with that
            // keyword -- confirmed directly against real `symbolgraph-extract` output (unlike the
            // two-fragment `"@"` + name-with-`preciseIdentifier` shape a *use* of the type as an
            // isolation attribute produces elsewhere, e.g. on some other declaration's own
            // fragments). Collected from `pathComponents` (the symbol's own bare name, e.g.
            // `["ThirdPartyActor"]` for a top-level type) rather than parsed out of the fragment
            // text, matching this file's own "never text/substring scanning" discipline.
            var discoveredGlobalActorNames: Set<String> = []
            for file in symbolFiles {
                guard let data = try? fileSystem.readData(at: file),
                      let document = try? JSONDecoder().decode(BulkSymbolGraphDocument.self, from: data) else { continue }
                for symbol in document.symbols {
                    let fragments = symbol.declarationFragments ?? []
                    fragmentsByUSR[symbol.identifier.precise] = fragments
                    if symbol.kind?.identifier == "swift.protocol" {
                        protocolUSRs.insert(symbol.identifier.precise)
                    }
                    if fragments.contains(where: { $0.kind == "attribute" && $0.spelling == "@globalActor" }),
                       let name = symbol.pathComponents?.last {
                        discoveredGlobalActorNames.insert(name)
                    }
                }
                for relationship in document.relationships {
                    switch relationship.kind {
                    case "memberOf": containerOfMember[relationship.source] = relationship.target
                    case "inheritsFrom": superclassOfType[relationship.source] = relationship.target
                    default: break
                    }
                }
            }

            // `GlobalActorNameValidation`'s allowlist originally needed the *project's own* real
            // `@globalActor`-declared names, meaningless here (this scans bulk-extracted SDK/
            // dependency modules, never the analyzed project's own source) -- left empty, only the
            // fixed `MainActor` fast path applying to bulk-extracted data. Issue #40: `this
            // module's own` discovered names (computed just above, same real compiler signal,
            // immune to the same StateObject/Router/resultBuilder confusability the name-matching
            // heuristic exists to prevent -- a literal `@globalActor` keyword on a symbol's own
            // declaration is unambiguous) now close exactly the real, reproduced gap the old
            // comment here called "vanishingly rare": a real dependency module declaring its own
            // custom global actor AND marking its own other APIs with it (confirmed via a minimal
            // repro -- `thirdPartyIsolatedWork()`'s own fragment, `{"kind":"attribute","spelling":
            // "ThirdPartyActor",...}`, was previously rejected here and permanently bulk-cached as
            // `.nonisolated`, short-circuiting the live-oracle path before it ever ran).
            // **Known, deliberately narrower than the live-oracle path**: this only ever sees names
            // declared within *this same module's own* extraction -- a global actor declared in
            // module A and used as a closure/declaration attribute only in a *different* bulk-
            // extracted module B is not covered (`extractAll`'s per-module jobs run independently);
            // `ExternalIsolationBackfill`'s live per-declaration query (`expandedGlobalActorNames`,
            // unioned project-wide) still closes that narrower case when it applies.
            let bulkKnownGlobalActorNames: Set<String> = discoveredGlobalActorNames

            // A type's own isolation, resolved via its superclass chain when its own fragments
            // carry no confirmed signal -- mirrors `IsolationInferenceEngine.resolveInheritedIsolation`'s
            // "a class mandatorily inherits its superclass's global actor isolation" rule (SE-0316),
            // just over bulk symbol-graph data instead of this project's own `DeclarationInfo`.
            // Memoized (thousands of symbols, real hierarchies several levels deep) with a
            // cycle guard matching that same engine's own defensive pattern.
            var typeIsolationCache: [String: IsolationKind] = [:]
            func resolvedTypeIsolation(_ usr: String, visiting: inout Set<String>) -> IsolationKind {
                if let cached = typeIsolationCache[usr] { return cached }
                guard visiting.insert(usr).inserted else { return .nonisolated }
                defer { visiting.remove(usr) }
                let fragments = fragmentsByUSR[usr] ?? []
                let result: IsolationKind
                if SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments, knownGlobalActorNames: bulkKnownGlobalActorNames) {
                    result = SymbolGraphIsolationParser.isolation(fromFragments: fragments, knownGlobalActorNames: bulkKnownGlobalActorNames)
                } else if let superclassUSR = superclassOfType[usr] {
                    result = resolvedTypeIsolation(superclassUSR, visiting: &visiting)
                } else {
                    result = .nonisolated
                }
                typeIsolationCache[usr] = result
                return result
            }

            var resolved: [String: IsolationKind] = [:]
            for (usr, fragments) in fragmentsByUSR {
                if SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments, knownGlobalActorNames: bulkKnownGlobalActorNames) {
                    resolved[usr] = SymbolGraphIsolationParser.isolation(fromFragments: fragments, knownGlobalActorNames: bulkKnownGlobalActorNames)
                    continue
                }
                // No confirmed signal on this symbol's own fragments. For a *member*, SE-0316 (the
                // same rule this project's own `IsolationInferenceEngine.resolveInheritedIsolation`
                // already trusts for project-local declarations, unconditionally, for the global-
                // actor case) makes this **not actually ambiguous**: a member with no isolation of
                // its own inherits its containing type's global-actor isolation, full stop -- there
                // is no third option in real Swift. The only way a member of a `@MainActor` class
                // *isn't* `@MainActor` is an explicit `nonisolated` on the member itself, and that
                // case is already handled *before* this fallback ever runs: `nonisolated` is a
                // `hasConfirmedIsolationSignal` match on the member's own fragments (confirmed
                // against a real UIKit extraction on this machine: 184 real members carry it), so a
                // member reaching this fallback with zero signal of its own genuinely has none to
                // report other than its container's. Confirmed directly against `UINavigationController
                // .pushViewController(_:animated:)`: real bulk-extracted fragments carry no attribute,
                // its container is confirmed `@MainActor`, and this now resolves it without a live
                // query at all.
                //
                // The `.actor` (not `.globalActor`) case is structurally out of scope here, not just
                // deliberately narrowed -- confirmed directly against `SymbolGraphIsolationParser.
                // isolation(fromFragments:)`: it only ever returns `.nonisolated` or `.globalActor`,
                // with no code path that recognizes a bulk-extracted `actor` type declaration at all
                // (a real, pre-existing gap, unrelated to this fix). `resolvedTypeIsolation` can
                // therefore never actually return `.actor` today, so the `guard containerIsolation ==
                // .nonisolated` below is defensive completeness, not something a real container hits
                // -- if that parser gap is ever closed, this still does the right thing (defer to a
                // live query) rather than needing another look. SE-0316 gives another reason this
                // would need care even if it were representable: actor isolation only propagates to
                // *instance* members (`IsolationInferenceEngine.resolveInheritedIsolation`'s own
                // `!declaration.isStaticMember` gate on that branch specifically, unlike
                // `.globalActor`'s unconditional one), and this bulk pass doesn't track static-vs-
                // instance at all. Apple's own SDKs essentially never declare a custom `actor` type
                // anyway, so this fallback's real-world impact is overwhelmingly the `@MainActor`
                // UIKit/AppKit member shape the fix above actually targets.
                //
                // A member of a container that resolves to `.nonisolated` (e.g. `Int.+=`, a member
                // of plain nonisolated `Int` -- a real regression caught by this project's own
                // existing golden fixtures when this check was first scoped too broadly to *every*
                // member regardless of its container) has nothing to have inherited, so its own
                // absence of an attribute is exactly as trustworthy as a non-member's, and still
                // resolves to `.nonisolated` below. Caching a wrong verdict here would be final -- a
                // bulk-cache hit is never re-checked -- so only the `.actor` case is still deferred to
                // a real call site's own live query, exactly as if this weren't a bulk-covered module.
                if let containerUSR = containerOfMember[usr] {
                    var visiting: Set<String> = []
                    let containerIsolation = resolvedTypeIsolation(containerUSR, visiting: &visiting)
                    if case .globalActor = containerIsolation {
                        resolved[usr] = containerIsolation
                        continue
                    }
                    guard containerIsolation == .nonisolated else { continue }
                }
                resolved[usr] = .nonisolated
            }
            return BulkSymbolGraphResolution(isolationByUSR: resolved, protocolUSRs: protocolUSRs, discoveredGlobalActorNames: discoveredGlobalActorNames)
        } catch {
            return BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: [])
        }
    }
}

/// Each `DispatchQueue.concurrentPerform` iteration writes exactly one distinct index, so despite
/// the Swift concurrency checker's conservative refusal to reason about indexed writes into a
/// captured `inout`/value-type buffer, this class-based indexed store is genuinely race-free: no
/// two concurrent iterations ever touch the same slot. Mirrors this project's existing
/// `ResultBox<T>: @unchecked Sendable` precedent (`SwiftIsolationMap.swift`) for the same reason --
/// a hand-verified safety argument the compiler can't itself express.
private final class ResultBuffer: @unchecked Sendable {
    private(set) var results: [BulkSymbolGraphResolution]

    init(count: Int) {
        results = Array(repeating: BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: []), count: count)
    }

    func set(_ value: BulkSymbolGraphResolution, at index: Int) {
        results[index] = value
    }
}

struct BulkSymbolGraphDocument: Decodable {
    let symbols: [Symbol]
    /// Defaulted, not required: older/malformed documents without a `relationships` array should
    /// still parse (just as "no member facts available"), not fail decoding of the whole file.
    let relationships: [Relationship]

    struct Symbol: Decodable {
        let identifier: Identifier
        /// Defaulted, not required: real `symbolgraph-extract` output always carries this, but a
        /// hand-written test fixture predating this field (or any other malformed/partial document)
        /// should still decode -- absence just means "kind unknown," never a decode failure for the
        /// whole symbol. See `BulkSymbolGraphResolution`'s own doc comment for why the real
        /// `"swift.protocol"` value matters: it's what tells a genuine protocol conformance apart
        /// from a class-bound protocol's inheritance-clause entry naming an actual class.
        let kind: Kind?
        let declarationFragments: [SymbolGraphDocument.Symbol.Fragment]?
        /// The symbol's own bare name path (e.g. `["ThirdPartyActor"]` for a top-level type,
        /// `["Outer", "Inner"]` for a nested one) -- confirmed present in real `symbolgraph-extract`
        /// output. Defaulted, not required, for the same hand-written-fixture reason as `kind`
        /// above. `.last` is this symbol's own bare name, used only for Issue #40's global-actor-
        /// name discovery (see `discoveredGlobalActorNames` above); every other consumer of this
        /// document keys purely by USR.
        let pathComponents: [String]?

        struct Identifier: Decodable {
            let precise: String
        }

        struct Kind: Decodable {
            let identifier: String
        }
    }

    /// `"kind": "memberOf"` relates a member (`source`) to its containing type (`target`) -- the
    /// fact `BulkSymbolGraphExtractor.extract` needs to know whether a symbol with no isolation
    /// attribute of its own could plausibly have one inherited from a container. `target` isn't
    /// read yet (this fix only needs "does *any* container exist", not "which one"), but is kept
    /// on the type so a future, fuller inheritance walk doesn't need to re-decode relationships.
    struct Relationship: Decodable {
        let kind: String
        let source: String
        let target: String
    }

    enum CodingKeys: String, CodingKey {
        case symbols, relationships
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbols = try container.decode([Symbol].self, forKey: .symbols)
        relationships = try container.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
    }
}
