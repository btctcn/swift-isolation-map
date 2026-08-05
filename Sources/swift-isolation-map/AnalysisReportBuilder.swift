import IsolationCore
import OutputFormat
import SyntaxAnalysis

/// Builds the machine-readable `AnalysisReport` from an already-resolved `IsolationInferenceEngine`
/// (Priority 1, unmodified) plus the Swift-version/rule-set strings `SwiftVersionDetection`
/// produced. All isolation resolution and cross-isolation-edge detection is delegated to the
/// engine -- this file only shapes that output and applies the risk heuristic below.
enum AnalysisReportBuilder {
    static let schemaVersion = "1.0"

    static func build(
        engine: IsolationInferenceEngine,
        swiftVersion: String,
        ruleSetUsed: String,
        toolVersion: String,
        unknownUSRs: Set<String> = [],
        closuresByFile: [String: [ClassifiedClosure]] = [:]
    ) -> AnalysisReport {
        let declarations = engine.declarations
        // A declaration with no location (never matched to a real IndexStoreDB symbol -- see
        // `DeclarationLinker`'s documented limitation) is real but un-locatable; reported at
        // file "" / line 0 rather than dropped, so it's still visible in `nodes` and countable
        // in the summary instead of silently disappearing.
        var nodes = declarations.keys.sorted().map { usr -> AnalysisNode in
            let declaration = declarations[usr]!
            return AnalysisNode(
                usr: usr,
                name: declaration.name,
                isolation: describe(engine.resolveIsolation(for: usr)),
                location: AnalysisLocation(file: declaration.location?.file ?? "", line: declaration.location?.line ?? 0)
            )
        }

        let edges = engine.crossIsolationEdges().map { edge -> AnalysisEdge in
            // §7.2's innermost-enclosing-closure rule (docs/task-closure-isolation-attribution.md):
            // if this call site falls inside a closure the project-wide accept-list recognizes
            // (Rule A/B), that closure's isolation -- not the declaration's own -- decides this
            // edge's risk. Nothing else about `edge.callerUSR`'s declaration changes: the node
            // entry below and every *other* edge from the same declaration still resolve through
            // `engine.resolveIsolation(for:)` untouched (§7.4's invariant).
            let declaredCallerIsolation = engine.resolveIsolation(for: edge.callerUSR)
            let callerIsolation = closuresByFile[edge.location.file].flatMap {
                effectiveCallerIsolation(atLine: edge.location.line, column: edge.location.column, in: $0)
            } ?? declaredCallerIsolation
            let calleeIsolation = engine.resolveIsolation(for: edge.calleeUSR)
            let risk = riskLevel(caller: callerIsolation, callee: calleeIsolation)
            // Orthogonal to `risk` (computed above, unchanged, still a pure function of the two
            // resolved `IsolationKind`s) -- whether either endpoint is a USR the compiled-
            // dependency oracle tried and failed to resolve, per
            // docs/task-compiled-dependency-isolation.md's binding requirement that "no idea"
            // must never be conflated with a confirmed risk.
            let isUnknown = unknownUSRs.contains(edge.callerUSR) || unknownUSRs.contains(edge.calleeUSR)
            return AnalysisEdge(
                callerUSR: edge.callerUSR,
                calleeUSR: edge.calleeUSR,
                callerIsolation: describe(callerIsolation),
                calleeIsolation: describe(calleeIsolation),
                risk: risk,
                explanation: isUnknown
                    ? "isolation for one side of this call could not be determined (compiled dependency, oracle resolution failed) -- not a confirmed risk"
                    : explanation(caller: callerIsolation, callee: calleeIsolation, risk: risk),
                location: AnalysisLocation(file: edge.location.file, line: edge.location.line),
                isUnknown: isUnknown
            )
        }

        // `crossIsolationEdges()` can reference a USR that has no entry in `declarations` at all
        // (e.g. a call into un-analyzed/external code -- it resolves to `.unspecified`, which
        // differs from any real isolation, so it still counts as "crossing"). Left alone, that
        // produces an edge whose endpoint has no matching node -- self-inconsistent output that
        // would draw a link to nowhere in both report writers. Synthesized here instead, once,
        // so the report itself (JSON included, not just the diagrams) is always internally
        // consistent: every edge endpoint has a node.
        let declaredUSRs = Set(declarations.keys)
        let edgeReferencedUSRs = Set(edges.flatMap { [$0.callerUSR, $0.calleeUSR] })
        let unresolvedUSRs = edgeReferencedUSRs.subtracting(declaredUSRs).sorted()
        nodes.append(contentsOf: unresolvedUSRs.map { usr in
            AnalysisNode(usr: usr, name: usr, isolation: describe(.unspecified), location: AnalysisLocation(file: "", line: 0))
        })

        // "Type" isn't a stored fact on `DeclarationInfo` (it uniformly models types and members
        // alike, see its own doc comment) and can't be recovered from the USR once
        // `DeclarationLinker` has rewritten placeholders to real IndexStoreDB USRs. Approximated
        // structurally: a declaration is a "type" if it's an actor, declares a conformance or
        // superclass (only types have those), is a nested type, or is some other declaration's
        // `containingTypeUSR`. Documented as a summary-only heuristic -- it never affects
        // isolation resolution or the edges/risk themselves, only the aggregate counts below.
        let containingTypeUSRs = Set(declarations.values.compactMap(\.containingTypeUSR))
        func isType(_ declaration: DeclarationInfo) -> Bool {
            declaration.isActorType
                || !declaration.conformances.isEmpty
                || declaration.superclassUSR != nil
                || declaration.isNestedType
                || containingTypeUSRs.contains(declaration.usr)
        }

        let typeDeclarations = declarations.values.filter(isType)
        let mainActorTypeCount = typeDeclarations.filter { isMainActor(engine.resolveIsolation(for: $0.usr)) }.count
        // `.unspecified` is never produced for a USR that's actually a key in `declarations` --
        // the engine's own resolution always bottoms out at `.nonisolated` (tier 5) for anything
        // it knows about; `.unspecified` only comes back for a USR it *doesn't* recognize (see
        // `IsolationInferenceEngine.resolveIsolation`'s `guard let declaration = ... else return
        // .unspecified`). So counting over `declarations.values` here would always be zero and
        // silently mean nothing. Counted instead over every USR the call graph actually
        // references (both call ends) -- a real, meaningful signal: how many symbols this
        // analysis's declarations don't cover at all (calls into un-analyzed/external code, or
        // an unresolved placeholder per `DeclarationLinker`'s own documented limitation).
        let referencedUSRs = Set(engine.callGraph.flatMap { [$0.callerUSR, $0.calleeUSR] })
        let unspecifiedCount = referencedUSRs.filter { engine.resolveIsolation(for: $0) == .unspecified }.count

        let summary = AnalysisSummary(
            typesAnalyzed: typeDeclarations.count,
            actors: typeDeclarations.filter(\.isActorType).count,
            mainActorTypes: mainActorTypeCount,
            unspecifiedIsolation: unspecifiedCount,
            crossActorBoundaries: edges.count,
            highRiskBoundaries: edges.filter { $0.risk == .high && !$0.isUnknown }.count
        )

        return AnalysisReport(
            schemaVersion: schemaVersion,
            toolVersion: toolVersion,
            swiftVersion: swiftVersion,
            ruleSetUsed: ruleSetUsed,
            summary: summary,
            nodes: nodes,
            edges: edges
        )
    }

    /// Structural, resolved-isolation-kind-based heuristic -- **not** `@unchecked Sendable`/
    /// `nonisolated(unsafe)`-aware data-race detection. By the time a project compiles, every
    /// cross-isolation call is already either `await`-ed or uses an explicit unsafe escape
    /// hatch; detecting the escape-hatch case needs new SwiftSyntax attribute extraction that
    /// doesn't exist yet (documented v0.2+ gap, not silently approximated here).
    /// - `high`: a `.nonisolated` caller reaching `.actor`/`.globalActor` state -- the classic
    ///   "nonisolated context reaching into isolated state" pattern.
    /// - `low`: both sides are actor-protected (crosses a boundary, but still compiler-enforced
    ///   via `await` on both ends).
    /// - `medium`: everything else that's still cross-isolation (e.g. either side `.unspecified`).
    static func riskLevel(caller: IsolationKind, callee: IsolationKind) -> RiskLevel {
        if case .nonisolated = caller, isIsolated(callee) {
            return .high
        }
        if isIsolated(caller), isIsolated(callee) {
            return .low
        }
        return .medium
    }

    private static func isIsolated(_ kind: IsolationKind) -> Bool {
        switch kind {
        case .actor, .globalActor: return true
        case .nonisolated, .unspecified: return false
        }
    }

    private static func isMainActor(_ kind: IsolationKind) -> Bool {
        if case .globalActor(let name) = kind {
            return name == "MainActor"
        }
        return false
    }

    private static func explanation(caller: IsolationKind, callee: IsolationKind, risk: RiskLevel) -> String {
        switch risk {
        case .high:
            return "nonisolated code reaches \(describe(callee))-isolated state -- no static isolation check protects this boundary"
        case .low:
            return "crosses an actor boundary between two isolated contexts (\(describe(caller)) -> \(describe(callee))), compiler-enforced via await"
        case .medium:
            return "crosses isolation from \(describe(caller)) to \(describe(callee))"
        }
    }

    private static func describe(_ kind: IsolationKind) -> String {
        switch kind {
        case .actor(let name): return "actor(\(name))"
        case .globalActor(let name): return "globalActor(\(name))"
        case .nonisolated: return "nonisolated"
        case .unspecified: return "unspecified"
        }
    }
}
