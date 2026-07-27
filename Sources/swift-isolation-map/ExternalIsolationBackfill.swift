import Foundation
import IsolationCore
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration

/// Result of resolving every USR referenced by the analyzed project but absent from its own
/// declarations -- external superclasses/protocols/call targets living in compiled dependencies.
struct ExternalIsolationResolution {
    /// New entries, keyed by an *external* USR (never a project-local one) -- safe to merge
    /// without ever overwriting an already-resolved project-local `DeclarationInfo`.
    let backfilledDeclarations: [String: DeclarationInfo]
    /// Existing *project-local* entries, rewritten (their `conformances[].protocolGlobalActorName`
    /// filled in) -- a deliberate overwrite of the original entry, not a new one. See "Why protocol
    /// conformance needs a different mechanism than superclass" below.
    let updatedDeclarations: [String: DeclarationInfo]
    /// USRs the oracle tried and failed to resolve (load/timeout/malformed response, or no
    /// candidate result matched at all) -- never populated for a successful match, even one with
    /// no isolation attribute (that's a real, positive `.nonisolated` fact, not unknown; see
    /// `SymbolGraphIsolationParser`'s own doc comment).
    let unknownUSRs: Set<String>
}

/// Resolves external isolation facts and prepares them for backfill into `declarations` *before*
/// `IsolationInferenceEngine` is constructed -- the engine itself stays completely unmodified
/// (docs/task-compiled-dependency-isolation.md's binding requirement), it just gets a fuller
/// `declarations` dictionary to work from, same shape it already handles for project-local facts.
///
/// Two trigger sources, not one -- verified against the real motivating bug
/// (docs/task-compiled-dependency-isolation.md section 2.1, `NewsTableCell`/`UITableViewCell`):
/// that bug is a pure inheritance-chain failure, not a call-graph-edge case at all, so an
/// edge-only trigger would never have caught it.
enum ExternalIsolationBackfill {
    /// `environmentProvider`/`bulkModuleNames` drive an eager, one-time bulk pre-resolution
    /// (`BulkSymbolGraphExtractor`) of well-known SDK modules (UIKit/AppKit/SwiftUI by default)
    /// *plus* every real third-party module `environmentProvider` discovers from the project's own
    /// build configuration (CocoaPods/XCFrameworks/SwiftPM dependencies) *before* either trigger
    /// runs -- performance-motivated, not a new source of truth (see `BulkSymbolGraphExtractor`'s
    /// own doc comment). Critically, `environmentProvider` is obtainable without ever running a
    /// real build (`BulkExtractionEnvironmentProviding`'s own contract) -- unlike the original
    /// hardcoded-3-module version of this bulk phase, which got its SDK/target by calling
    /// `compilerArguments.compilerArguments(forFile:)`, the same expensive, `clean`-build-capable
    /// provider the live fallback needs. That one premature call is what made the live provider's
    /// slow path run even when the bulk cache alone would have covered everything -- removing it
    /// is the entire fix: `compilerArguments` is now only ever touched from inside `query(...)`'s
    /// live fallback, which already only runs on a genuine bulk-cache miss.
    static func resolve(
        linked: LinkedAnalysis,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        processRunning: ProcessRunning,
        environmentProvider: BulkExtractionEnvironmentProviding,
        bulkModuleNames: [String] = BulkSymbolGraphExtractor.defaultModules
    ) async -> ExternalIsolationResolution {
        var backfilled: [String: DeclarationInfo] = [:]
        var updated: [String: DeclarationInfo] = [:]
        var unknown: Set<String> = []

        let bulkCache = bulkSymbolGraphCache(
            environmentProvider: environmentProvider, processRunning: processRunning,
            fileSystem: fileSystem, moduleNames: bulkModuleNames
        )

        await resolveEdgeLevelTriggers(
            linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
            bulkCache: bulkCache, backfilled: &backfilled, unknown: &unknown
        )
        await resolveDeclarationLevelTriggers(
            linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
            bulkCache: bulkCache, backfilled: &backfilled, updated: &updated, unknown: &unknown
        )

        return ExternalIsolationResolution(backfilledDeclarations: backfilled, updatedDeclarations: updated, unknownUSRs: unknown)
    }

    /// Fail-soft: if the environment can't be determined at all (an unrecognized platform, a
    /// `-showBuildSettings`/`--show-bin-path` failure), the bulk cache is simply empty and every
    /// USR falls through to the live oracle -- today's exact prior behavior when bulk didn't apply.
    private static func bulkSymbolGraphCache(
        environmentProvider: BulkExtractionEnvironmentProviding,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying,
        moduleNames: [String]
    ) -> [String: IsolationKind] {
        guard let environment = try? environmentProvider.environment() else { return [:] }
        return BulkSymbolGraphExtractor.extractAll(
            moduleNames: moduleNames, discoveredModules: environment.discoveredModules,
            sdkPath: environment.sdkPath, target: environment.target,
            processRunning: processRunning, fileSystem: fileSystem
        )
    }

    // MARK: - Edge-level trigger (direct calls into external code, no subclassing involved)

    /// A call-graph edge whose callee is absent from `declarations` -- query cursor-info at the
    /// edge's own real location (already known, from `IndexStoreIntegration`) and select the
    /// result by strict USR equality against `edge.calleeUSR`. No ambiguity about "does the caller
    /// have its own override" the way the declaration-level trigger has, because this asks the
    /// oracle about the exact callee, directly, at the exact call site.
    private static func resolveEdgeLevelTriggers(
        linked: LinkedAnalysis,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        bulkCache: [String: IsolationKind],
        backfilled: inout [String: DeclarationInfo],
        unknown: inout Set<String>
    ) async {
        var queried: Set<String> = []
        for edge in linked.callGraph {
            let targetUSR = edge.calleeUSR
            guard linked.declarations[targetUSR] == nil, backfilled[targetUSR] == nil, !queried.contains(targetUSR) else { continue }
            queried.insert(targetUSR)

            switch await query(
                targetUSR: targetUSR, file: edge.location.file, line: edge.location.line, utf8Column: edge.location.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: bulkCache
            ) {
            case .resolved(let isolation):
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false
                )
            case .unknown:
                unknown.insert(targetUSR)
            }
        }
    }

    // MARK: - Declaration-level trigger (external superclass/protocol conformance)

    /// A project-local declaration referencing an external superclass and/or protocol, with no
    /// explicit isolation of its own -- queried at *its own* declaration location (the spike's
    /// proven "hover the project's own declaration" shape: the result is the declaration's
    /// already-fully-resolved effective isolation, inheritance included). Only declarations with
    /// no explicit isolation of their own are safe representatives: if a declaration overrides its
    /// inherited isolation explicitly, its own effective isolation no longer equals what its
    /// superclass/protocol alone would contribute, so it must not be used to backfill facts about
    /// them (and, since the engine already checks `explicitIsolation` before ever consulting
    /// inheritance, such a declaration doesn't need this backfill for its own sake either).
    ///
    /// **Why protocol conformance needs a different mechanism than superclass**: confirmed by
    /// reading `IsolationInferenceEngine.resolveInheritedIsolation` directly -- the superclass
    /// branch does a real `declarations[superclassUSR]` lookup, so backfilling a new entry there
    /// is exactly what it needs. The protocol-conformance branches do **no such lookup** -- they
    /// read `conformance.protocolGlobalActorName` directly off the `ProtocolConformance` value
    /// already attached to the declaration. Backfilling `declarations[protocolUSR]` for an
    /// external protocol would therefore have zero effect; the fix has to rewrite the conforming
    /// declaration's own `conformances` array instead, mirroring `DeclarationLinker.relink`'s
    /// existing precedent for the project-local case.
    /// Gap B Phase I3's dedup outcome for one (nominal type, unresolved protocol) pair -- cached
    /// so every member sharing the exact same still-unresolved conformance (after Phase I2's
    /// `.baseOf`-based USR resolution, this is now genuinely rare: only same-bare-name collisions,
    /// unresolved-nominal edge cases, or a real external protocol the bulk cache doesn't cover)
    /// only ever pays for one live oracle round trip, not one per member.
    private enum ConformancePairOutcome {
        case globalActor(String)
        case notGlobalActor
        case unknown
    }

    /// Keyed the same way Phase I2's own member->nominal derivation is
    /// (`containingTypeUSR ?? usr`, `IndexStoreIntegration.DeclarationLinker`'s
    /// `resolveInheritanceViaBaseOfRelation`) -- deliberately not a second, parallel "which nominal
    /// does this declaration belong to" mechanism; the two live in different modules so can't
    /// literally share one map, but must agree on one derivation.
    private struct ConformancePairKey: Hashable {
        let nominalUSR: String
        let protocolUSR: String
    }

    private static func nominalUSR(for declaration: DeclarationInfo) -> String {
        declaration.containingTypeUSR ?? declaration.usr
    }

    private static func resolveDeclarationLevelTriggers(
        linked: LinkedAnalysis,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        bulkCache: [String: IsolationKind],
        backfilled: inout [String: DeclarationInfo],
        updated: inout [String: DeclarationInfo],
        unknown: inout Set<String>
    ) async {
        // Per-member conformance-need duplication dedup (Gap B Phase I3): `SyntaxAnalysis.
        // DeclarationExtractor` attaches a copy of the enclosing type's conformances to every
        // member's own `DeclarationInfo` -- confirmed against the real `~/ios` corpus (the same
        // clause, `needs=...`, counted once per member of the conforming type/extension). A
        // superclass need never has this duplication (`DeclarationExtractor.emitMember` always
        // sets `superclassUSR: nil` on a member; only a type's own entry ever carries one, so it's
        // already naturally deduped by the `backfilled[superclassUSR] == nil` check below) -- this
        // cache exists only for conformances.
        var conformancePairOutcomes: [ConformancePairKey: ConformancePairOutcome] = [:]

        for declaration in linked.declarations.values {
            guard declaration.explicitIsolation == nil, declaration.enclosingExtensionIsolation == nil else { continue }

            var unresolvedSuperclassUSR = declaration.superclassUSR.flatMap { superclassUSR in
                linked.declarations[superclassUSR] == nil && backfilled[superclassUSR] == nil ? superclassUSR : nil
            }
            var unresolvedConformanceIndices = declaration.conformances.indices.filter { index in
                let conformance = declaration.conformances[index]
                guard conformance.protocolGlobalActorName == nil,
                      conformance.declaredInSameFileAsPrimaryDefinition || conformance.declaredInSameContextAsWitness,
                      linked.declarations[conformance.protocolUSR] == nil else { return false }
                return true
            }
            guard unresolvedSuperclassUSR != nil || !unresolvedConformanceIndices.isEmpty else { continue }

            // Bulk-cache fast path: satisfy whichever needs a bulk-extracted SDK module already
            // answers -- the external symbol's own real isolation, keyed directly by USR -- so the
            // live per-declaration query below only ever runs for what's genuinely left over.
            // Checking each protocol's *own* isolation directly here is actually more precise than
            // the live query's fallback (which infers a shared actor name from the conforming
            // type's single effective isolation, not each individual protocol's own).
            var conformances = declaration.conformances
            var conformancesChanged = false
            if let superclassUSR = unresolvedSuperclassUSR, let cachedIsolation = bulkCache[superclassUSR] {
                backfilled[superclassUSR] = DeclarationInfo(
                    usr: superclassUSR, name: superclassUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false
                )
                unresolvedSuperclassUSR = nil
            }
            unresolvedConformanceIndices = unresolvedConformanceIndices.filter { index in
                guard case .globalActor(let actorName)? = bulkCache[conformances[index].protocolUSR] else { return true }
                conformances[index] = ProtocolConformance(
                    protocolUSR: conformances[index].protocolUSR,
                    protocolGlobalActorName: actorName,
                    declaredInSameFileAsPrimaryDefinition: conformances[index].declaredInSameFileAsPrimaryDefinition,
                    declaredInSameContextAsWitness: conformances[index].declaredInSameContextAsWitness
                )
                conformancesChanged = true
                return false
            }

            // Phase I3's own pair-cache fast path: apply an already-known (nominal, protocol)
            // outcome from an earlier member of the same type, cache-and-apply rather than
            // skip-and-leave (an earlier skip-only design would have left this copy `syntactic:`-
            // resolved-but-unapplied, silently losing rule 8's input on this member).
            let nominal = nominalUSR(for: declaration)
            unresolvedConformanceIndices = unresolvedConformanceIndices.filter { index in
                guard let outcome = conformancePairOutcomes[ConformancePairKey(nominalUSR: nominal, protocolUSR: conformances[index].protocolUSR)] else {
                    return true
                }
                if case .globalActor(let actorName) = outcome {
                    conformances[index] = ProtocolConformance(
                        protocolUSR: conformances[index].protocolUSR,
                        protocolGlobalActorName: actorName,
                        declaredInSameFileAsPrimaryDefinition: conformances[index].declaredInSameFileAsPrimaryDefinition,
                        declaredInSameContextAsWitness: conformances[index].declaredInSameContextAsWitness
                    )
                    conformancesChanged = true
                }
                return false
            }
            if conformancesChanged {
                updated[declaration.usr] = rebuilt(declaration, conformances: conformances)
            }

            guard unresolvedSuperclassUSR != nil || !unresolvedConformanceIndices.isEmpty,
                  let location = declaration.location else { continue }

            switch await query(
                targetUSR: declaration.usr, file: location.file, line: location.line, utf8Column: location.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: bulkCache
            ) {
            case .resolved(let isolation):
                if let superclassUSR = unresolvedSuperclassUSR {
                    backfilled[superclassUSR] = DeclarationInfo(
                        usr: superclassUSR, name: superclassUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false
                    )
                }
                if !unresolvedConformanceIndices.isEmpty {
                    let outcome: ConformancePairOutcome = {
                        if case .globalActor(let actorName) = isolation { return .globalActor(actorName) }
                        return .notGlobalActor
                    }()
                    for index in unresolvedConformanceIndices {
                        conformancePairOutcomes[ConformancePairKey(nominalUSR: nominal, protocolUSR: conformances[index].protocolUSR)] = outcome
                    }
                    if case .globalActor(let actorName) = isolation {
                        var liveConformances = conformancesChanged ? conformances : declaration.conformances
                        for index in unresolvedConformanceIndices {
                            liveConformances[index] = ProtocolConformance(
                                protocolUSR: liveConformances[index].protocolUSR,
                                protocolGlobalActorName: actorName,
                                declaredInSameFileAsPrimaryDefinition: liveConformances[index].declaredInSameFileAsPrimaryDefinition,
                                declaredInSameContextAsWitness: liveConformances[index].declaredInSameContextAsWitness
                            )
                        }
                        updated[declaration.usr] = rebuilt(declaration, conformances: liveConformances)
                    }
                }
            case .unknown:
                for index in unresolvedConformanceIndices {
                    conformancePairOutcomes[ConformancePairKey(nominalUSR: nominal, protocolUSR: conformances[index].protocolUSR)] = .unknown
                }
                // Mark the declaration itself, plus its direct members (one level of containing-
                // type propagation -- covers the common case, e.g. a method whose isolation
                // recurses into its containing type's, per `resolveInheritedIsolation`'s own
                // containingTypeUSR branch). Deeper nesting is a documented, known limitation, not
                // silently assumed away -- see docs/priority-3-phase-c-oracle-triggers.md.
                unknown.insert(declaration.usr)
                for other in linked.declarations.values where other.containingTypeUSR == declaration.usr {
                    unknown.insert(other.usr)
                }
            }
        }
    }

    private static func rebuilt(_ declaration: DeclarationInfo, conformances: [ProtocolConformance]) -> DeclarationInfo {
        DeclarationInfo(
            usr: declaration.usr,
            name: declaration.name,
            explicitIsolation: declaration.explicitIsolation,
            isActorType: declaration.isActorType,
            containingTypeUSR: declaration.containingTypeUSR,
            isStaticMember: declaration.isStaticMember,
            superclassUSR: declaration.superclassUSR,
            conformances: conformances,
            isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
            enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
            isNestedType: declaration.isNestedType,
            location: declaration.location
        )
    }

    // MARK: - Shared oracle query

    private enum QueryOutcome {
        case resolved(IsolationKind)
        case unknown
    }

    /// One `sourcekitd` cursor-info round trip: resolve compiler arguments + byte offset, send the
    /// request, select the result by USR, parse isolation (symbol-graph primary, XML fallback).
    /// Every failure mode -- compiler-args unavailable, offset conversion failure, the query
    /// itself throwing, no USR match among the results, or a matched result whose isolation can't
    /// be parsed at all -- becomes `.unknown`, never a crash and never a silent `.nonisolated`.
    private static func query(
        targetUSR: String,
        file: String,
        line: Int,
        utf8Column: Int,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        bulkCache: [String: IsolationKind]
    ) async -> QueryOutcome {
        // The primary win for the edge-level trigger: a direct call into a bulk-covered SDK
        // module (e.g. `someUIView.someMethod()`) resolves from an in-memory dictionary, no
        // `sourcekitd` round trip at all. A no-op lookup for the declaration-level trigger's own
        // `targetUSR` (always a project-local declaration, never itself in an SDK module's cache).
        if let cached = bulkCache[targetUSR] {
            return .resolved(cached)
        }
        do {
            let rawArguments = try compilerArguments.compilerArguments(forFile: file)
            // `compilerArguments(forFile:)` faithfully returns the real build's real (frontend-
            // level, for SwiftPM) arguments -- `sourcekitd`'s `key.compilerargs` needs driver-
            // level arguments instead, confirmed empirically (docs/priority-3-phase-e-fixtures.md).
            let arguments = CompilerArgumentsSanitizing.sanitized(rawArguments)
            let offset = try UTF8OffsetLocator.utf8Offset(inFile: file, line: line, utf8Column: utf8Column, fileSystem: fileSystem)
            let result = try await sourceKitD.cursorInfo(CursorInfoRequest(sourceFile: file, byteOffset: offset, compilerArguments: arguments))
            guard let symbol = USRMatching.select(from: result, targetUSR: targetUSR) else { return .unknown }
            if let symbolGraphJSON = symbol.symbolGraphJSON, let isolation = SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: symbolGraphJSON) {
                return .resolved(isolation)
            }
            if let xml = symbol.fullyAnnotatedDeclXML, let isolation = FullyAnnotatedDeclParser.isolation(fromXML: xml) {
                return .resolved(isolation)
            }
            return .unknown
        } catch {
            return .unknown
        }
    }
}
