import Foundation
import IsolationCore
import SyntaxAnalysis

public struct LinkedAnalysis: Equatable, Sendable {
    public let declarations: [String: DeclarationInfo]
    public let callGraph: [CallGraphEdge]
    /// Every closure literal found across every linked file, already classified against the
    /// project-wide accept-list (`docs/task-closure-isolation-attribution.md` §7.3.1), keyed by
    /// file path -- the same key `CallGraphEdge.location.file` uses, so
    /// `AnalysisReportBuilder` can look up "closures in this edge's file" directly.
    public let closuresByFile: [String: [ClassifiedClosure]]
    /// Every `await <expr>` range found across every linked file, keyed by file path -- the same
    /// key `CallGraphEdge.location.file` uses, so `AnalysisReportBuilder` can look up "awaited
    /// ranges in this edge's file" directly (docs/task-await-aware-risk-classification.md, issue
    /// #46). Unlike `closuresByFile`, needs no project-wide classification step -- just a merge.
    public let awaitedRangesByFile: [String: [AwaitedRange]]
    /// Every real `@globalActor`-declared name found anywhere across every linked file (the same
    /// project-wide union `link()` already computes internally for closure-attribute
    /// classification), exposed so `ExternalIsolationBackfill`'s live-oracle queries can tell a
    /// real global actor name from an arbitrary property wrapper/result builder that merely
    /// resolves to *some* real type via USR -- see `GlobalActorNameValidation`'s own doc comment.
    public let globalActorNames: Set<String>
    /// Every `@preconcurrency import Foo`'s top-level module name, keyed by the *importing* file
    /// path -- the same key `CallGraphEdge.location.file` uses, so `AnalysisReportBuilder`'s
    /// severity-downgrade lookup can look up "did this edge's own caller file `@preconcurrency
    /// import` the callee's module" directly (docs/task-escape-hatch-and-preconcurrency-severity.md,
    /// PR2, shape 4). Reduced to a `Set` per file (not a list of ranges like `awaitedRangesByFile`)
    /// -- unlike an `await` expression's own range, only "is this module name present at all in
    /// this file's own import list" ever matters, never a source position.
    public let preconcurrencyImportedModulesByFile: [String: Set<String>]

    public init(
        declarations: [String: DeclarationInfo], callGraph: [CallGraphEdge],
        closuresByFile: [String: [ClassifiedClosure]] = [:], awaitedRangesByFile: [String: [AwaitedRange]] = [:],
        globalActorNames: Set<String> = [], preconcurrencyImportedModulesByFile: [String: Set<String>] = [:]
    ) {
        self.declarations = declarations
        self.callGraph = callGraph
        self.closuresByFile = closuresByFile
        self.awaitedRangesByFile = awaitedRangesByFile
        self.globalActorNames = globalActorNames
        self.preconcurrencyImportedModulesByFile = preconcurrencyImportedModulesByFile
    }
}

/// The trickiest new logic in Priority 2 Phase 3: reconciles Phase 1's per-file, syntactic-
/// placeholder `DeclarationInfo`s (produced independently, one file at a time, by
/// `SyntaxAnalysis.DeclarationExtractor`) into one real, cross-file-correct analysis, using
/// IndexStoreDB as the source of real USRs and the real call graph.
///
/// Two distinct cross-file gaps get closed here, not one:
/// 1. **USR identity** -- a placeholder like `"syntactic:Widget"` only means anything within the
///    file it came from; this rewrites `usr`/`containingTypeUSR`/`superclassUSR`/`protocolUSR` to
///    IndexStoreDB's real USRs by matching declarations to real symbol occurrences at the same
///    (file, line, column) -- confirmed empirically that SwiftSyntax's and IndexStoreDB's
///    location conventions agree (1-based line, UTF-8-byte column, both measured at the name
///    token), see docs/priority-2-phase-3-linking.md.
/// 2. **`protocolGlobalActorName` backfill** -- Phase 1 computes this purely syntactically, per
///    file; a conformance to a protocol declared in a *different* file than the conforming
///    type/witness necessarily comes out `nil` from that file's own extraction alone (SwiftSyntax
///    has no notion of other files, and IndexStoreDB can't help here either -- confirmed in
///    Phase 0 that IndexStoreDB's symbol kind can't even distinguish `actor` from `class`, let
///    alone see a `@MainActor` attribute). Closed by merging every file's own
///    `protocolGlobalActorNames` map (from `ExtractionResult`) and backfilling any conformance
///    that came out `nil`, keyed by the protocol name embedded in its syntactic placeholder.
///
/// **Known, documented limitation:** when a type has *no* primary declaration among the files
/// being linked (only extensions, e.g. a type defined in a file outside the analyzed set), its
/// type-level placeholder USR is never resolved (no location to match against) and multiple such
/// unresolved entries for the same name can overwrite each other in the final dictionary. This
/// doesn't produce an incorrect *resolution* for rule 7 (whole-type inference already correctly
/// requires the primary declaration to be in the same file, per Phase 1's design) -- it can only
/// discard already-irrelevant-to-rule-7 data, not corrupt a real answer.
///
/// **A related, more serious case, closed this session
/// (docs/task-cross-file-type-entry-collision.md): a type *with* a primary declaration in the
/// linked set, but *also* extended in a different file, could have its own rich entry (superclass,
/// conformances, real location) silently overwritten by an empty one from the other file's own
/// independent, primary-declaration-blind extraction.** Both files' per-file extractions produce
/// their own `"syntactic:<Name>"` placeholder for the same type (`SyntaxAnalysis` has no notion of
/// other files by design), both correctly rewrite to the same real USR, and used to collide via a
/// plain dictionary overwrite (`byUSR[linked.usr] = linked`) -- whichever file's entry was
/// processed last won, discarding the other's facts entirely, non-deterministically (file
/// processing order is not a meaningful tiebreaker). Fixed by merging on collision instead of
/// overwriting (see `merged(_:_:)` below) -- confirmed real on `Project Iris`
/// (`AppDelegate: MindboxAppDelegate`'s own superclass link was being silently destroyed by an
/// unrelated test target's own `extension AppDelegate { ... }`).
public struct DeclarationLinker {
    let indexStore: IndexStoreQuerying

    public init(indexStore: IndexStoreQuerying) {
        self.indexStore = indexStore
    }

    /// Every declaration whose own placeholder USR never resolved via `buildUSRRewriteMap`'s
    /// location-based matching -- paired with the real source location this project's own
    /// `SyntaxAnalysis` extraction found for it, so a caller can attempt a live, per-declaration
    /// fallback resolution (docs/task-indexstore-declaration-completeness.md) before falling back
    /// to `link()`'s own "leave it as `syntactic:`, `IsolationInferenceEngine` treats that as
    /// `.unspecified`" default. Declarations with no real location (fixture-only, never extracted
    /// from a file) are skipped -- there's no position to query live against.
    ///
    /// Deliberately a separate, cheap pass (just `buildUSRRewriteMap`, not the rest of `link()`'s
    /// work) rather than baked into `link()` itself: the live fallback this exists for is
    /// `async`, and `DeclarationLinker` stays synchronous by design (see this type's own doc
    /// comment) -- the caller resolves the async part between this call and `link(_:
    /// usrRewriteMapOverrides:)`.
    public func unresolvedPlaceholders(for extractionResults: [ExtractionResult]) -> [(placeholder: String, location: SymbolLocation)] {
        let allDeclarations = extractionResults.flatMap(\.declarations)
        let usrRewriteMap = buildUSRRewriteMap(for: allDeclarations).map
        return allDeclarations.compactMap { declaration in
            guard declaration.usr.hasPrefix("syntactic:"), usrRewriteMap[declaration.usr] == nil,
                  let location = declaration.location else {
                return nil
            }
            return (declaration.usr, location)
        }
    }

    /// `usrRewriteMapOverrides` -- from `unresolvedPlaceholders(for:)` plus a live fallback
    /// resolution -- take priority over whatever `buildUSRRewriteMap`'s own location-based match
    /// found (or didn't) for the same placeholder: a live, authoritative `sourcekitd` answer for
    /// a specific declaration is never less trustworthy than the bulk index's own miss.
    /// `additionalGlobalActorNames` -- Issue #40 -- lets a caller fold in global-actor names this
    /// project's own syntactic scan can never see by construction (a real `@globalActor` type
    /// declared in a *compiled* dependency, discovered instead via `BulkSymbolGraphExtractor
    /// .discoveredGlobalActorNames`). Unioned in before `classify(_:knownGlobalActorNames:)` ever
    /// runs below, so Rule A recognizes such a name exactly the same way it already recognizes a
    /// project-local one -- and before `LinkedAnalysis.globalActorNames` is assembled, so
    /// `ExternalIsolationBackfill`'s own live-oracle `GlobalActorNameValidation` calls (which read
    /// `linked.globalActorNames`) get the same expanded set for free, with no separate plumbing.
    public func link(
        _ extractionResults: [ExtractionResult], usrRewriteMapOverrides: [String: String] = [:],
        additionalGlobalActorNames: Set<String> = []
    ) -> LinkedAnalysis {
        let allDeclarations = extractionResults.flatMap(\.declarations)

        var mergedProtocolGlobalActorNames: [String: String] = [:]
        var mergedProtocolRequirementGlobalActorNames: [String: [String: String]] = [:]
        var mergedProtocolInheritedProtocolNames: [String: Set<String>] = [:]
        var mergedGlobalActorNames: Set<String> = additionalGlobalActorNames
        for result in extractionResults {
            mergedProtocolGlobalActorNames.merge(result.protocolGlobalActorNames) { existing, _ in existing }
            for (protocolName, requirementNames) in result.protocolRequirementGlobalActorNames {
                mergedProtocolRequirementGlobalActorNames[protocolName, default: [:]].merge(requirementNames) { existing, _ in existing }
            }
            for (protocolName, superNames) in result.protocolInheritedProtocolNames {
                mergedProtocolInheritedProtocolNames[protocolName, default: []].formUnion(superNames)
            }
            mergedGlobalActorNames.formUnion(result.globalActorNames)
        }

        // Transitive protocol-inheritance expansion (docs/task-transitive-protocol-conformance.md):
        // a *conforming type's* own conformance list only ever names the protocol it directly
        // wrote (`LetterPickerBar: PlatformView`), never that protocol's own ancestry
        // (`PlatformView: View`) -- confirmed a real, reproduced gap on Swiftfin via a real
        // `swiftc` repro: an entirely unrelated, unattributed member of a type conforming to
        // `PlatformView` is still real `@MainActor` ("main actor-isolated property... can not be
        // referenced from a nonisolated context"), because `PlatformView` itself transitively
        // conforms to `View` -- a real, external, whole-protocol `@MainActor` protocol -- and
        // SE-0316 whole-type inference doesn't care how many protocol-inheritance hops separate
        // the conforming type from the actor-isolated ancestor. Expanding every declaration's own
        // conformance list to include every transitive ancestor (walked here, once, project-wide,
        // over `mergedProtocolInheritedProtocolNames` -- a real protocol-inheritance graph, so a
        // cycle guard is required even though Swift itself forbids a *directly* circular one) lets
        // every existing mechanism downstream (`relink`'s same-name backfill,
        // `ExternalIsolationBackfill`'s live-query dispatch for a same-file/same-context external
        // conformance, `IsolationInferenceEngine`'s unmodified rule 7/8) pick the new entry up
        // exactly as if the type had written `: View` directly -- no other code needs to change.
        func transitiveAncestorNames(of protocolName: String) -> Set<String> {
            var visited: Set<String> = []
            var frontier = [protocolName]
            while let current = frontier.popLast() {
                guard let superNames = mergedProtocolInheritedProtocolNames[current] else { continue }
                for superName in superNames where !visited.contains(superName) {
                    visited.insert(superName)
                    frontier.append(superName)
                }
            }
            return visited
        }
        func transitivelyExpanded(_ conformances: [ProtocolConformance]) -> [ProtocolConformance] {
            var expanded = conformances
            var seenBareNames = Set(conformances.compactMap { conformance -> String? in
                guard conformance.protocolUSR.hasPrefix("syntactic:") else { return nil }
                return String(conformance.protocolUSR.dropFirst("syntactic:".count))
            })
            for conformance in conformances {
                guard conformance.protocolUSR.hasPrefix("syntactic:") else { continue }
                let bareName = String(conformance.protocolUSR.dropFirst("syntactic:".count))
                for ancestorName in transitiveAncestorNames(of: bareName) where !seenBareNames.contains(ancestorName) {
                    seenBareNames.insert(ancestorName)
                    expanded.append(ProtocolConformance(
                        protocolUSR: "syntactic:\(ancestorName)",
                        protocolGlobalActorName: nil,
                        declaredInSameFileAsPrimaryDefinition: conformance.declaredInSameFileAsPrimaryDefinition,
                        declaredInSameContextAsWitness: conformance.declaredInSameContextAsWitness
                    ))
                }
            }
            return expanded
        }

        // Rule A/B classification (docs/task-closure-isolation-attribution.md §7.1 step 2): can
        // only happen now, project-wide, not inside any single file's own extraction -- whether a
        // closure-signature attribute names a global actor depends on the *whole run's* declared
        // actors, not just the declaring file's own.
        var closuresByFile: [String: [ClassifiedClosure]] = [:]
        for result in extractionResults {
            for record in result.closureLiteralRecords {
                let classified = ClassifiedClosure(
                    startLine: record.startLine, startColumn: record.startColumn,
                    endLine: record.endLine, endColumn: record.endColumn,
                    isolationOverride: classify(record, knownGlobalActorNames: mergedGlobalActorNames)
                )
                closuresByFile[record.file, default: []].append(classified)
            }
        }

        var awaitedRangesByFile: [String: [AwaitedRange]] = [:]
        for result in extractionResults {
            for range in result.awaitedRanges {
                awaitedRangesByFile[range.file, default: []].append(range)
            }
        }

        var preconcurrencyImportedModulesByFile: [String: Set<String>] = [:]
        for result in extractionResults {
            for module in result.preconcurrencyImportedModules {
                preconcurrencyImportedModulesByFile[module.file, default: []].insert(module.moduleName)
            }
        }

        let (builtUSRRewriteMap, ownUSRByLocation, filesWithIndexedSymbols) = buildUSRRewriteMap(for: allDeclarations)
        var usrRewriteMap = builtUSRRewriteMap
        for (placeholder, realUSR) in usrRewriteMapOverrides {
            usrRewriteMap[placeholder] = realUSR
        }

        // Nesting-mismatch fallback (Gap B Phase I2, per external review): a nested type's own
        // declaration placeholder is qualified (`"syntactic:Outer.Inner"`, from
        // `SyntacticIdentity.typeUSR(_:)`), but a bare-name inheritance-clause/extension reference
        // to that same type is never qualified (`"syntactic:Inner"`, from `typeUSR(named:)`) --
        // confirmed a real, separate bug by directly reading `SyntacticIdentity`'s two USR-building
        // functions. A direct `usrRewriteMap` lookup for the bare-name reference therefore always
        // misses even though the qualified declaration resolved just fine. Precomputed once (not
        // scanned per lookup): every resolved qualified placeholder indexed by its own bare
        // (rightmost-component) name, so a miss on the direct lookup can fall back to "the unique
        // qualified key ending in `.<name>`" -- multiple matches must fall through unresolved
        // rather than guess, same "never guess" philosophy as `disambiguate`.
        var nestedKeysByBareName: [String: [String]] = [:]
        for key in usrRewriteMap.keys {
            guard key.hasPrefix("syntactic:") else { continue }
            let qualified = key.dropFirst("syntactic:".count)
            guard let dotIndex = qualified.lastIndex(of: ".") else { continue }
            let bareName = String(qualified[qualified.index(after: dotIndex)...])
            nestedKeysByBareName[bareName, default: []].append(key)
        }
        func rewritten(_ usr: String) -> String {
            if let real = usrRewriteMap[usr] { return real }
            guard usr.hasPrefix("syntactic:") else { return usr }
            let bareName = String(usr.dropFirst("syntactic:".count))
            guard let candidates = nestedKeysByBareName[bareName], candidates.count == 1,
                  let real = usrRewriteMap[candidates[0]] else {
                return usr
            }
            return real
        }

        // A cross-reference (`containingTypeUSR`/`superclassUSR`/a conformance's `protocolUSR`) is
        // a *bare name*, resolved through the same project-wide, purely string-keyed
        // `usrRewriteMap` as `rewritten(_:)` above -- with no notion of which file is asking.
        // Confirmed a real, reproduced bug on `Swiftfin`: `GestureView` and `SliderContainer` are
        // each declared *twice*, once under `Swiftfin/` (the iOS target) and once under
        // `Swiftfin tvOS/` (the tvOS target) -- two wholly unrelated types that happen to share a
        // name. Analyzing only the iOS scheme means the tvOS file is never compiled, so it has no
        // real indexed symbols of its own -- but its members' `containingTypeUSR` is still the
        // bare `"syntactic:GestureView"` placeholder, and `usrRewriteMap["syntactic:GestureView"]`
        // *does* resolve (to the iOS type's own real USR, via the iOS declaration's own location
        // match). The tvOS members silently inherited the iOS type's real USR as their own
        // `containingTypeUSR`, making `ExternalIsolationBackfill`'s conformance-pair claim loop
        // treat them as extra, competing "members of `GestureView`" -- one of them (sorted first:
        // `"Swiftfin tvOS/..."` < `"Swiftfin/..."` by plain string comparison) claimed the
        // (GestureView, PlatformViewRepresentable) pair and dispatched its live query at the
        // *tvOS* file's location, which the compiler-arguments provider can't resolve (that file
        // isn't part of the analyzed target at all) -- so the query failed, the pair's outcome
        // stayed unresolved, and the *real* iOS `GestureView.makeUIView` (genuinely
        // `@MainActor`, confirmed against `UIViewRepresentable`'s real `.swiftinterface` and a
        // real `swiftc` repro) never got a chance to claim it, coming out `nonisolated` instead.
        // A legitimate multi-file reference to the same real type (the already-supported "primary
        // declaration in one file, conformance added via an extension in another" shape) always
        // requires that other file to itself be part of the compiled target, hence have *some*
        // real indexed symbols -- so gating the fallback on the referring declaration's own file
        // having any real indexed symbols at all rejects exactly the coincidental-same-name case
        // without touching the legitimate one.
        func rewrittenReference(_ usr: String, referringFile: String?) -> String {
            // No location info at all (synthetic/fixture-only declarations, never a real
            // extracted one -- `DeclarationExtractor.emitMember`/`emitTypeDeclarationIfNeeded`
            // always set a real location) is not evidence of being from an uncompiled file, so it
            // falls through to the unrestricted rewrite exactly as before this fix -- only a
            // *known*, definitely-uncompiled file withholds the rewrite.
            if let referringFile, !filesWithIndexedSymbols.contains(referringFile) {
                return usr
            }
            return rewritten(usr)
        }

        var byUSR: [String: DeclarationInfo] = [:]
        for declaration in allDeclarations {
            let referringFile = declaration.location?.file
            let relinkedConformances = transitivelyExpanded(declaration.conformances).map { conformance in
                relink(
                    conformance, witnessName: declaration.name, referringFile: referringFile, rewrittenReference: rewrittenReference,
                    mergedProtocolGlobalActorNames: mergedProtocolGlobalActorNames,
                    mergedProtocolRequirementGlobalActorNames: mergedProtocolRequirementGlobalActorNames
                )
            }
            // Prefer the declaration's own, independently-disambiguated location match over the
            // shared, bare-name-keyed `usrRewriteMap` for *its own* identity -- see
            // `buildUSRRewriteMap`'s `ownUSRByLocation` doc comment (issue #95). Only falls back to
            // `rewritten(_:)` when this declaration's own location has no direct match (no real
            // location at all, or its own disambiguation genuinely failed) -- identical to the
            // prior behavior for every declaration that isn't part of a same-name collision.
            let ownUSR = declaration.location.flatMap { ownUSRByLocation[LocationKey(location: $0)] } ?? rewritten(declaration.usr)
            let linked = DeclarationInfo(
                usr: ownUSR,
                name: declaration.name,
                explicitIsolation: declaration.explicitIsolation,
                isActorType: declaration.isActorType,
                containingTypeUSR: declaration.containingTypeUSR.map { rewrittenReference($0, referringFile: referringFile) },
                isStaticMember: declaration.isStaticMember,
                superclassUSR: declaration.superclassUSR.map { rewrittenReference($0, referringFile: referringFile) },
                conformances: relinkedConformances,
                isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
                enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
                isNestedType: declaration.isNestedType,
                location: declaration.location,
                isImmutableStoredProperty: declaration.isImmutableStoredProperty,
                isActorInitializer: declaration.isActorInitializer,
                hasPreconcurrencyAttribute: declaration.hasPreconcurrencyAttribute,
                isNonisolatedUnsafe: declaration.isNonisolatedUnsafe,
                moduleName: declaration.moduleName
            )
            if let existing = byUSR[linked.usr] {
                byUSR[linked.usr] = Self.merged(existing, linked, filesWithIndexedSymbols: filesWithIndexedSymbols)
            } else {
                byUSR[linked.usr] = linked
            }
        }

        byUSR = resolveInheritanceViaBaseOfRelation(byUSR)
        byUSR = resolveExtensionContainingTypeViaChildOfRelation(byUSR)

        let knownUSRs = Set(usrRewriteMap.values)
        var rawCallGraph: [CallGraphEdge] = []
        for realUSR in knownUSRs {
            rawCallGraph.append(contentsOf: indexStore.callGraphEdges(forUSR: realUSR))
        }

        // `callGraphEdges(forUSR:)` above is a reverse lookup keyed by a USR this project already
        // knows about, so it can never surface an edge whose *callee* is external -- see
        // `RawIndexStoreClient.callSites(inFile:)`'s own doc comment for the full explanation. Scan
        // every analyzed file's call sites too and fold in only the ones `callGraphEdges` couldn't
        // have found (callee not already known), so the combined `callGraph` can, for the first
        // time, contain edges into compiled-dependency code -- exactly what the compiled-
        // dependency-isolation oracle's edge-level trigger needs
        // (docs/task-compiled-dependency-isolation.md), and what `IsolationInferenceEngine.
        // crossIsolationEdges()` (unmodified) will evaluate correctly once such a callee's
        // isolation is backfilled into `declarations`.
        let filesToQuery = Set(allDeclarations.compactMap { $0.location?.file })
        for file in filesToQuery {
            for edge in indexStore.callSites(inFile: file) where !knownUSRs.contains(edge.calleeUSR) {
                rawCallGraph.append(edge)
            }
        }

        // Canonicalize both sides of every edge through IndexStoreDB's own `.accessorOf` relation
        // -- a property read/write is recorded as a call to that property's *synthesized accessor*
        // (a USR distinct from the property's own), which would otherwise make every property
        // access anywhere in the codebase look like an unresolvable external reference, even for
        // completely ordinary project-local properties (confirmed empirically against `Project Iris`: 60%
        // of edge-level "external" misses carried the project's own module USR prefix -- see
        // docs/task-compiled-dependency-isolation-usr-granularity.md). Both `callerUSR` and
        // `calleeUSR` are rewritten, not just the callee: a call originating inside a property
        // observer body (`willSet`/`didSet`) could plausibly have its `.calledBy` relation
        // attributed to the observer's own accessor-suffixed USR, and `IsolationInferenceEngine
        // .resolveIsolation(for:)` treats any USR absent from `declarations` as `.unspecified` with
        // no special-casing between the two sides. Memoized per `link()` call (matching
        // `usrRewriteMap`'s own lifetime) -- `IndexStoreDB` queries are in-process local reads, but
        // a hot property's accessor can appear on thousands of edges.
        var accessorOwnerCache: [String: String] = [:]
        func canonicalized(_ usr: String) -> String {
            if let cached = accessorOwnerCache[usr] { return cached }
            let resolved = indexStore.owningPropertyUSR(forUSR: usr) ?? usr
            accessorOwnerCache[usr] = resolved
            return resolved
        }
        let callGraph = rawCallGraph.map { edge in
            CallGraphEdge(callerUSR: canonicalized(edge.callerUSR), calleeUSR: canonicalized(edge.calleeUSR), location: edge.location)
        }

        return LinkedAnalysis(
            declarations: byUSR, callGraph: callGraph, closuresByFile: closuresByFile,
            awaitedRangesByFile: awaitedRangesByFile, globalActorNames: mergedGlobalActorNames,
            preconcurrencyImportedModulesByFile: preconcurrencyImportedModulesByFile
        )
    }

    /// Gap B Phase I2's core fix (docs/task-gap-b-implementation-plan.md): resolves whatever
    /// `superclassUSR`/`conformances[].protocolUSR` placeholders are *still* `syntactic:`-prefixed
    /// after the location-based rewrite above, via IndexStoreDB's `.baseOf` relation
    /// (`IndexStoreClient.baseTypeUSRs(forUSR:)`). The location-based rewrite only ever resolves a
    /// declaration's *own* identity, never a *reference* to another declaration's name -- every
    /// inheritance-clause placeholder is a bare "syntactic:<Name>" string, produced once per file
    /// with no notion of other files, so it never matches any real symbol's own location. This
    /// pass closes that gap for both project-local references (which then match an entry already
    /// in `byUSR`, short-circuiting `ExternalIsolationBackfill`'s oracle trigger entirely -- the
    /// H-local fix) and external/SDK references (which resolve to their own real, compiler-mangled
    /// USR and route through the bulk-symbol-graph-cache-first oracle machinery instead of failing
    /// a live query against a nonsense placeholder name -- the H-external fix).
    ///
    /// **Query the nominal, not the member.** `.baseOf` is a type-level relation -- querying it
    /// against a *member*'s own USR (a method/property) returns nothing, since members have no
    /// base types of their own. But the real corpus's `needs=` lists overwhelmingly ride on
    /// *member* declarations, because `SyntaxAnalysis.DeclarationExtractor` attaches a copy of the
    /// enclosing type's conformances to every member's own `DeclarationInfo` (see
    /// `ExternalIsolationBackfill`'s own per-member-duplication finding). So for a member, the
    /// nominal to query is `declaration.containingTypeUSR` (already rewritten to a real USR by the
    /// loop above, wherever the containing type itself resolved) -- reusing this existing field
    /// rather than inventing a second, parallel member->nominal derivation. For a top-level or
    /// nested type's own entry, the nominal is the declaration's own (already-rewritten) `usr`.
    /// Resolved once per distinct nominal (memoized): a type conformed-to by hundreds of members
    /// is only ever queried once.
    private func resolveInheritanceViaBaseOfRelation(_ byUSR: [String: DeclarationInfo]) -> [String: DeclarationInfo] {
        var baseTypeNamesByNominal: [String: [String: String]] = [:]

        // Every real base type/protocol `nominalUSR` inherits from, indexed by bare name --
        // memoized per nominal. Same-bare-name collisions (e.g. `ModuleA.Foo`/`ModuleB.Foo` both
        // trimming to `"Foo"`) are skipped, not guessed, matching `disambiguate`'s own "return nil
        // rather than guess" philosophy -- this same per-nominal map is also the mechanism
        // `ExternalIsolationBackfill`'s own per-member dedup (Phase I3) keys against, so the two
        // phases share one "which nominal does this declaration belong to" answer, not two.
        //
        // A collision is only real when the *same name* maps to two *different* USRs. Confirmed
        // against a real project (`OldPurchaseReturnViewController: UIViewController`) that
        // `IndexStoreDB.occurrences(relatedToUSR:roles:.baseOf)` can report one real base type
        // twice, verbatim-identical USR both times -- an earlier version of this loop treated any
        // repeated name as a collision regardless of whether the USR actually differed, silently
        // dropping a real, unambiguous base type (`UIViewController`) and leaving the subclass
        // incorrectly `nonisolated` instead of inheriting `@MainActor`. A repeated identical
        // (name, USR) pair is a harmless duplicate occurrence, not an ambiguity.
        func baseTypeNames(forNominal nominalUSR: String) -> [String: String] {
            if let cached = baseTypeNamesByNominal[nominalUSR] { return cached }
            var byName: [String: String] = [:]
            var collidedNames: Set<String> = []
            for candidate in indexStore.baseTypeUSRs(forUSR: nominalUSR) {
                if let existingUSR = byName[candidate.name] {
                    if existingUSR != candidate.usr {
                        collidedNames.insert(candidate.name)
                    }
                } else {
                    byName[candidate.name] = candidate.usr
                }
            }
            for name in collidedNames { byName.removeValue(forKey: name) }
            baseTypeNamesByNominal[nominalUSR] = byName
            return byName
        }

        func nominalUSR(for declaration: DeclarationInfo) -> String {
            declaration.containingTypeUSR ?? declaration.usr
        }

        // Resolves one placeholder against `declaration`'s own nominal -- `nil` (leave the
        // placeholder as-is) if the nominal itself never resolved to a real USR (Phase I2 can't
        // help there; the nesting-mismatch fallback above is the only thing that can), or if the
        // bare name has no unique match among the nominal's own base types.
        func resolved(_ placeholder: String, for declaration: DeclarationInfo) -> String? {
            guard placeholder.hasPrefix("syntactic:") else { return nil }
            let nominal = nominalUSR(for: declaration)
            guard !nominal.hasPrefix("syntactic:") else { return nil }
            let bareName = String(placeholder.dropFirst("syntactic:".count))
            return baseTypeNames(forNominal: nominal)[bareName]
        }

        return byUSR.mapValues { declaration in
            var superclassUSR = declaration.superclassUSR
            if let current = superclassUSR, let realUSR = resolved(current, for: declaration) {
                superclassUSR = realUSR
            }
            let conformances = declaration.conformances.map { conformance -> ProtocolConformance in
                guard let realUSR = resolved(conformance.protocolUSR, for: declaration) else { return conformance }
                return ProtocolConformance(
                    protocolUSR: realUSR,
                    protocolGlobalActorName: conformance.protocolGlobalActorName,
                    declaredInSameFileAsPrimaryDefinition: conformance.declaredInSameFileAsPrimaryDefinition,
                    declaredInSameContextAsWitness: conformance.declaredInSameContextAsWitness,
                    isUnchecked: conformance.isUnchecked,
                    isPreconcurrency: conformance.isPreconcurrency
                )
            }
            guard superclassUSR != declaration.superclassUSR || conformances != declaration.conformances else {
                return declaration
            }
            return DeclarationInfo(
                usr: declaration.usr,
                name: declaration.name,
                explicitIsolation: declaration.explicitIsolation,
                isActorType: declaration.isActorType,
                containingTypeUSR: declaration.containingTypeUSR,
                isStaticMember: declaration.isStaticMember,
                superclassUSR: superclassUSR,
                conformances: conformances,
                isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
                enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
                isNestedType: declaration.isNestedType,
                location: declaration.location,
                isImmutableStoredProperty: declaration.isImmutableStoredProperty,
                isActorInitializer: declaration.isActorInitializer,
                hasPreconcurrencyAttribute: declaration.hasPreconcurrencyAttribute,
                isNonisolatedUnsafe: declaration.isNonisolatedUnsafe,
                moduleName: declaration.moduleName
            )
        }
    }

    /// Extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md):
    /// resolves a member's `containingTypeUSR` when it's still `syntactic:`-prefixed because the
    /// extended type has no primary declaration among the linked files (a genuinely external
    /// SDK/Pods type, or a project-local type simply not in this analysis run's file set) --
    /// via IndexStoreDB's `.childOf`/`.extendedBy` relation chain, never a location or a name
    /// (the extension's own `extendedType` token position is recorded nowhere in `DeclarationInfo`,
    /// and capturing it would require a `SyntaxAnalysis` change this fix deliberately avoids).
    ///
    /// **Two hops, kept as two distinct calls, per an external review's own amendment**: the
    /// naive-but-convenient alternative -- resolve once per shared bare-name placeholder
    /// (`"syntactic:UIViewController"`) and fan the answer out to every member pointing at it --
    /// would silently reintroduce exactly the collision the bare-name scheme already has (every
    /// extension of anything *named* `UIViewController` anywhere in the project, Pods sources
    /// included, sharing one answer). Hop 1 runs per member (`containingExtensionUSR`, a fast,
    /// in-memory index lookup) and naturally produces the correct per-extension grouping for free
    /// -- two different extension blocks, even of the same-named type, have distinct synthetic
    /// USRs of their own, so no placeholder-based grouping ever needs to exist in this pass at all.
    /// Hop 2 (`extendedTypeUSR`) is memoized per distinct extension USR, not per member, mirroring
    /// Gap B's own per-nominal memoization precedent (`resolveInheritanceViaBaseOfRelation`'s
    /// `baseTypeNames`).
    ///
    /// **Residual, evidenced limitation**: a member whose own `usr` never resolved to a real USR
    /// (this declaration's own location-based linking failed, for whatever reason) has no hop-1
    /// entry point at all -- it's left exactly as it is today (placeholder containing type,
    /// `.nonisolated`, false-positive-only per this task's own verified scope note, never a worse
    /// outcome than before this fix).
    private func resolveExtensionContainingTypeViaChildOfRelation(_ byUSR: [String: DeclarationInfo]) -> [String: DeclarationInfo] {
        var extendedTypeUSRByExtension: [String: String?] = [:]

        func extendedTypeUSR(forExtensionUSR extensionUSR: String) -> String? {
            if let cached = extendedTypeUSRByExtension[extensionUSR] { return cached }
            let resolved = indexStore.extendedTypeUSR(forExtensionUSR: extensionUSR)
            extendedTypeUSRByExtension[extensionUSR] = resolved
            return resolved
        }

        return byUSR.mapValues { declaration in
            guard let containingTypeUSR = declaration.containingTypeUSR,
                  containingTypeUSR.hasPrefix("syntactic:"),
                  !declaration.usr.hasPrefix("syntactic:") else {
                return declaration
            }
            guard let extensionUSR = indexStore.containingExtensionUSR(forMemberUSR: declaration.usr),
                  let realContainingTypeUSR = extendedTypeUSR(forExtensionUSR: extensionUSR) else {
                return declaration
            }
            return DeclarationInfo(
                usr: declaration.usr,
                name: declaration.name,
                explicitIsolation: declaration.explicitIsolation,
                isActorType: declaration.isActorType,
                containingTypeUSR: realContainingTypeUSR,
                isStaticMember: declaration.isStaticMember,
                superclassUSR: declaration.superclassUSR,
                conformances: declaration.conformances,
                isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
                enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
                isNestedType: declaration.isNestedType,
                location: declaration.location,
                isImmutableStoredProperty: declaration.isImmutableStoredProperty,
                isActorInitializer: declaration.isActorInitializer,
                hasPreconcurrencyAttribute: declaration.hasPreconcurrencyAttribute,
                isNonisolatedUnsafe: declaration.isNonisolatedUnsafe,
                moduleName: declaration.moduleName
            )
        }
    }

    private func relink(
        _ conformance: ProtocolConformance,
        witnessName: String,
        referringFile: String?,
        rewrittenReference: (String, String?) -> String,
        mergedProtocolGlobalActorNames: [String: String],
        mergedProtocolRequirementGlobalActorNames: [String: [String: String]]
    ) -> ProtocolConformance {
        var globalActorName = conformance.protocolGlobalActorName
        if globalActorName == nil, conformance.protocolUSR.hasPrefix("syntactic:") {
            let protocolName = String(conformance.protocolUSR.dropFirst("syntactic:".count))
            // Whole-protocol attribute first, exactly like the same-file case in
            // `DeclarationExtractor.emitMember` -- a per-requirement attribute only ever applies
            // to the witness whose own name matches that specific requirement.
            globalActorName = mergedProtocolGlobalActorNames[protocolName] ?? mergedProtocolRequirementGlobalActorNames[protocolName]?[witnessName]
        }
        return ProtocolConformance(
            protocolUSR: rewrittenReference(conformance.protocolUSR, referringFile),
            protocolGlobalActorName: globalActorName,
            declaredInSameFileAsPrimaryDefinition: conformance.declaredInSameFileAsPrimaryDefinition,
            declaredInSameContextAsWitness: conformance.declaredInSameContextAsWitness,
            isUnchecked: conformance.isUnchecked,
            isPreconcurrency: conformance.isPreconcurrency
        )
    }

    /// `filesWithIndexedSymbols` -- every file the real index actually has *any* symbol for --
    /// exists purely to let `link()` refuse to trust a bare-name cross-reference
    /// (`containingTypeUSR`/`superclassUSR`/`protocolUSR`) coming from a file that isn't one of
    /// them. See `link()`'s own `rewrittenReference` doc comment for the real, confirmed bug this
    /// guards against.
    ///
    /// `ownUSRByLocation` -- the same per-declaration `match.usr` this loop already computes,
    /// keyed by *that declaration's own location* instead of its (potentially colliding) bare
    /// placeholder string -- exists for `link()`'s own identity rewrite (issue #95). A top-level
    /// `"syntactic:<Name>"` placeholder is a bare name with no file/module qualification
    /// (`SyntacticIdentity.typeUSR(_:)`), so two genuinely different, unrelated real declarations
    /// that merely share a name (confirmed real on `Project Iris`: the app's own `LogLevel` enum
    /// and the `MindboxLogger` pod's own, completely unrelated `LogLevel` enum) both write into
    /// `usrRewriteMap` under the identical key, and only the last one processed during iteration
    /// survives -- even though *this* loop already correctly disambiguated each one independently
    /// via its own real location, one line above the collision. `ownUSRByLocation` preserves that
    /// already-correct, per-declaration answer instead of discarding it.
    private func buildUSRRewriteMap(for declarations: [DeclarationInfo]) -> (map: [String: String], ownUSRByLocation: [LocationKey: String], filesWithIndexedSymbols: Set<String>) {
        let filesToQuery = Set(declarations.compactMap { $0.location?.file })
        var candidatesByLocation: [LocationKey: [IndexedSymbol]] = [:]
        var filesWithIndexedSymbols: Set<String> = []
        for file in filesToQuery {
            let symbols = indexStore.definedSymbols(inFile: file)
            if !symbols.isEmpty {
                filesWithIndexedSymbols.insert(file)
            }
            for symbol in symbols {
                candidatesByLocation[LocationKey(location: symbol.location), default: []].append(symbol)
            }
        }

        var usrRewriteMap: [String: String] = [:]
        var ownUSRByLocation: [LocationKey: String] = [:]
        for declaration in declarations {
            guard let location = declaration.location,
                  let candidates = candidatesByLocation[LocationKey(location: location)],
                  let match = Self.disambiguate(candidates: candidates, declarationName: declaration.name) else {
                continue
            }
            usrRewriteMap[declaration.usr] = match.usr
            ownUSRByLocation[LocationKey(location: location)] = match.usr
        }
        return (usrRewriteMap, ownUSRByLocation, filesWithIndexedSymbols)
    }

    /// Multiple real symbols can share the exact same (line, column) -- confirmed empirically: a
    /// plain stored property's implicit getter/setter report at the same location as the
    /// property itself, and an actor's implicit synthesized `init()` reports at the same location
    /// as the actor type declaration. Disambiguates by name where possible:
    /// - Exact match handles types and properties (IndexStoreDB's `currentUser` vs.
    ///   `getter:currentUser`/`setter:currentUser` are textually distinct).
    /// - Prefix-before-"(" handles methods with parameter labels, where IndexStoreDB's symbol
    ///   name includes them (`login(as:)`) but this extractor's `DeclarationInfo.name` is only
    ///   the base name (`login`, matching `node.name.text`).
    /// - A single candidate needs no disambiguation at all.
    /// Returns `nil` (no confident match) rather than guessing when multiple candidates remain
    /// after both heuristics -- an unresolved placeholder USR is a known, visible limitation;
    /// silently picking the wrong symbol would not be.
    static func disambiguate(candidates: [IndexedSymbol], declarationName: String) -> IndexedSymbol? {
        if candidates.count == 1 { return candidates[0] }
        if let exact = candidates.first(where: { $0.name == declarationName }) { return exact }
        if let prefixMatch = candidates.first(where: { $0.name.hasPrefix("\(declarationName)(") }) { return prefixMatch }
        return nil
    }

    /// Merges two per-file `DeclarationInfo`s that both rewrote to the same real USR -- the
    /// cross-file type-entry collision fix (docs/task-cross-file-type-entry-collision.md): a type
    /// with a primary declaration in one file and an extension in another each get their own,
    /// independent per-file entry from `SyntaxAnalysis` (which has no notion of other files), and
    /// both correctly rewrite to the identical real USR. Field-by-field rules, each informed by
    /// what `DeclarationExtractor.swift` can actually make differ between two such entries (not
    /// guessed):
    /// - `superclassUSR`/`isActorType`/`explicitIsolation`: only a *primary* declaration can ever
    ///   set these (`applyInheritance`/`recordPrimaryDeclaration`'s own construction) -- at most one
    ///   side is ever non-nil/true in practice, so preferring whichever is present is safe, not a
    ///   guess between two conflicting real facts.
    /// - `location`: the one field where *both* sides genuinely can be non-nil for two unrelated
    ///   reasons -- the legitimate cross-file case above (where, per the previous bullet, only one
    ///   side ever really has one) and a second, real, confirmed shape this project's own corpus
    ///   hygiene sweep found (issue #123, docs/task-own-module-declaration-gaps.md §4): two *actual
    ///   primary* declarations of "the same" type, because the source tree contains a stray,
    ///   uncompiled duplicate file (a Finder `" 2.swift"` copy) alongside the real one -- both
    ///   syntactically parsed, both with their own real, non-nil location. Left to plain `??`
    ///   before this fix, the winner depended on whichever file `SyntaxAnalysis` happened to process
    ///   first (in practice, a lexical file-path sort -- confirmed real on Project Iris: `"...2.swift"`'s
    ///   own leading space, `0x20`, sorts before `.swift`'s `.`, `0x2E`), with no relation to which
    ///   file is actually real. `filesWithIndexedSymbols` (already computed for the unrelated
    ///   `rewrittenReference` guard above -- "every file the real index actually has *any* symbol
    ///   for") is exactly the right, already-available signal: a stray file that's never part of any
    ///   compiled target has zero real indexed symbols, so its location loses the tie-break to a
    ///   location backed by real indexing, with no new dependency (a live compiler-arguments lookup,
    ///   this project's own doc comment for the issue's original discovery had proposed) needed.
    ///   Falls back to the original, unconditional `??` (whichever side is `existing`, i.e.
    ///   processed first) when both or neither side's file is indexed -- covers both the legitimate
    ///   cross-file case (only one side non-nil, `??` picks it regardless of indexing) and the
    ///   degenerate case of two stray files sharing a USR (indexing can't distinguish them either;
    ///   no worse than before).
    /// - `conformances`: concatenated, not picked -- both sides can carry real, *different*
    ///   conformances (the entire shape of the bug: one file's own extension states a conformance
    ///   the other file's entry never saw), and each `ProtocolConformance` already carries its own
    ///   correctly-computed-per-file rule 7/8 flags, so concatenation preserves both without
    ///   recomputing anything.
    /// - `isEligibleForModuleDefaultIsolation`: conservative AND -- each side only ever saw its
    ///   *own* conformances when computing this, so a disqualifying `Sendable`/`SendableMetatype`
    ///   conformance declared in the *other* file wouldn't be visible to the side that didn't see
    ///   it; ANDing keeps the real SE-0466 exclusion correct regardless of which file it came from.
    /// Commutative in every field but `conformances`' own array *order* (concatenation order
    /// depends on which side is `existing` vs. `incoming`) -- harmless, since every conformances
    /// consumer (`IsolationInferenceEngine`) searches the whole array for a match, never depends on
    /// order.
    static func merged(
        _ existing: DeclarationInfo, _ incoming: DeclarationInfo, filesWithIndexedSymbols: Set<String> = []
    ) -> DeclarationInfo {
        DeclarationInfo(
            usr: existing.usr,
            name: existing.name,
            explicitIsolation: existing.explicitIsolation ?? incoming.explicitIsolation,
            isActorType: existing.isActorType || incoming.isActorType,
            containingTypeUSR: existing.containingTypeUSR ?? incoming.containingTypeUSR,
            isStaticMember: existing.isStaticMember || incoming.isStaticMember,
            superclassUSR: existing.superclassUSR ?? incoming.superclassUSR,
            conformances: existing.conformances + incoming.conformances,
            isEligibleForModuleDefaultIsolation: existing.isEligibleForModuleDefaultIsolation && incoming.isEligibleForModuleDefaultIsolation,
            enclosingExtensionIsolation: existing.enclosingExtensionIsolation ?? incoming.enclosingExtensionIsolation,
            isNestedType: existing.isNestedType || incoming.isNestedType,
            location: preferredLocation(existing.location, incoming.location, filesWithIndexedSymbols: filesWithIndexedSymbols),
            isImmutableStoredProperty: existing.isImmutableStoredProperty || incoming.isImmutableStoredProperty,
            isActorInitializer: existing.isActorInitializer || incoming.isActorInitializer,
            hasPreconcurrencyAttribute: existing.hasPreconcurrencyAttribute || incoming.hasPreconcurrencyAttribute,
            isNonisolatedUnsafe: existing.isNonisolatedUnsafe || incoming.isNonisolatedUnsafe,
            moduleName: existing.moduleName ?? incoming.moduleName
        )
    }

    /// See `merged(_:_:filesWithIndexedSymbols:)`'s own `location` bullet for the real, confirmed
    /// gap (issue #123) this closes and why `filesWithIndexedSymbols` is the right signal.
    private static func preferredLocation(
        _ existing: SymbolLocation?, _ incoming: SymbolLocation?, filesWithIndexedSymbols: Set<String>
    ) -> SymbolLocation? {
        guard let existing else { return incoming }
        guard let incoming else { return existing }
        let existingIsIndexed = filesWithIndexedSymbols.contains(existing.file)
        let incomingIsIndexed = filesWithIndexedSymbols.contains(incoming.file)
        if existingIsIndexed != incomingIsIndexed {
            return incomingIsIndexed ? incoming : existing
        }
        return existing
    }
}

private struct LocationKey: Hashable {
    let file: String
    let line: Int
    let column: Int

    init(location: IsolationCore.SymbolLocation) {
        self.file = location.file
        self.line = location.line
        self.column = location.column
    }
}
