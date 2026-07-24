import Foundation
import IsolationCore
import SyntaxAnalysis

public struct LinkedAnalysis: Equatable, Sendable {
    public let declarations: [String: DeclarationInfo]
    public let callGraph: [CallGraphEdge]
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
/// discard already-irrelevant-to-rule-7 data, not corrupt a real answer. A full general solution
/// (merging every extension-only fragment of a type across files) is out of scope for what this
/// phase's "done" criterion (a cross-file protocol-witness call resolving correctly) requires.
public struct DeclarationLinker {
    let indexStore: IndexStoreQuerying

    public init(indexStore: IndexStoreQuerying) {
        self.indexStore = indexStore
    }

    public func link(_ extractionResults: [ExtractionResult]) -> LinkedAnalysis {
        let allDeclarations = extractionResults.flatMap(\.declarations)

        var mergedProtocolGlobalActorNames: [String: String] = [:]
        for result in extractionResults {
            mergedProtocolGlobalActorNames.merge(result.protocolGlobalActorNames) { existing, _ in existing }
        }

        let usrRewriteMap = buildUSRRewriteMap(for: allDeclarations)
        func rewritten(_ usr: String) -> String { usrRewriteMap[usr] ?? usr }

        var byUSR: [String: DeclarationInfo] = [:]
        for declaration in allDeclarations {
            let relinkedConformances = declaration.conformances.map { conformance in
                relink(conformance, rewritten: rewritten, mergedProtocolGlobalActorNames: mergedProtocolGlobalActorNames)
            }
            let linked = DeclarationInfo(
                usr: rewritten(declaration.usr),
                name: declaration.name,
                explicitIsolation: declaration.explicitIsolation,
                isActorType: declaration.isActorType,
                containingTypeUSR: declaration.containingTypeUSR.map(rewritten),
                isStaticMember: declaration.isStaticMember,
                superclassUSR: declaration.superclassUSR.map(rewritten),
                conformances: relinkedConformances,
                isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
                enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
                isNestedType: declaration.isNestedType,
                location: declaration.location
            )
            byUSR[linked.usr] = linked
        }

        var callGraph: [CallGraphEdge] = []
        for realUSR in Set(usrRewriteMap.values) {
            callGraph.append(contentsOf: indexStore.callGraphEdges(forUSR: realUSR))
        }

        return LinkedAnalysis(declarations: byUSR, callGraph: callGraph)
    }

    private func relink(
        _ conformance: ProtocolConformance,
        rewritten: (String) -> String,
        mergedProtocolGlobalActorNames: [String: String]
    ) -> ProtocolConformance {
        var globalActorName = conformance.protocolGlobalActorName
        if globalActorName == nil, conformance.protocolUSR.hasPrefix("syntactic:") {
            let protocolName = String(conformance.protocolUSR.dropFirst("syntactic:".count))
            globalActorName = mergedProtocolGlobalActorNames[protocolName]
        }
        return ProtocolConformance(
            protocolUSR: rewritten(conformance.protocolUSR),
            protocolGlobalActorName: globalActorName,
            declaredInSameFileAsPrimaryDefinition: conformance.declaredInSameFileAsPrimaryDefinition,
            declaredInSameContextAsWitness: conformance.declaredInSameContextAsWitness
        )
    }

    private func buildUSRRewriteMap(for declarations: [DeclarationInfo]) -> [String: String] {
        let filesToQuery = Set(declarations.compactMap { $0.location?.file })
        var candidatesByLocation: [LocationKey: [IndexedSymbol]] = [:]
        for file in filesToQuery {
            for symbol in indexStore.definedSymbols(inFile: file) {
                candidatesByLocation[LocationKey(location: symbol.location), default: []].append(symbol)
            }
        }

        var usrRewriteMap: [String: String] = [:]
        for declaration in declarations {
            guard let location = declaration.location,
                  let candidates = candidatesByLocation[LocationKey(location: location)],
                  let match = Self.disambiguate(candidates: candidates, declarationName: declaration.name) else {
                continue
            }
            usrRewriteMap[declaration.usr] = match.usr
        }
        return usrRewriteMap
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
