import IsolationCore
import OutputFormat
import SyntaxAnalysis

/// `--sort`'s two orderings. `ExpressibleByArgument`/`CaseIterable` conformances live in
/// `SwiftIsolationMap.swift` next to `OutputFormatOption`'s (this type has no CLI dependency of
/// its own, so it's declared here where `AnalysisReportBuilder.sorted` actually uses it).
enum EdgeSortOption: String {
    case file
    case severity
}

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
        closuresByFile: [String: [ClassifiedClosure]] = [:],
        awaitedRangesByFile: [String: [AwaitedRange]] = [:],
        preconcurrencyImportedModulesByFile: [String: Set<String>] = [:]
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

        let escapeHatches = escapeHatchFindings(from: declarations, preconcurrencyImportedModulesByFile: preconcurrencyImportedModulesByFile)

        // Issue #41 (Rule C): iterates every real call-graph edge, not just `engine
        // .crossIsolationEdges()`'s own pre-filtered subset -- that filter compares *declared*
        // caller/callee isolation only (`IsolationInferenceEngine`, Priority 1, has no notion of
        // closures at all), so a call inside `Task.detached { }`/a non-main `DispatchQueue` written
        // *inside a method already declared on the same actor as its callee* (the design doc's own
        // motivating `Task.detached { self.someMainActorMethod() }` example) would never even reach
        // this loop: `declaredCallerIsolation == calleeIsolation` (both the same actor), so `engine
        // .crossIsolationEdges()` excludes it before any closure override is ever consulted --
        // confirmed a real, would-have-shipped gap by writing this exact fixture as a test first
        // and watching it fail. `includeEdge` below is the fix: true when *either* the declared
        // view crosses (Rule A/B's own case -- unchanged, still shown at whatever risk the closure
        // override computes) *or* the closure-corrected effective view crosses (Rule C's own new
        // case, additive). When no closure applies at all, `callerIsolation == declaredCallerIsolation`
        // makes the two conditions identical, so this is a strict superset of the previous edge set,
        // never a narrower one -- Rule A/B's existing golden fixtures are unaffected by construction.
        let edges = engine.callGraph.compactMap { edge -> AnalysisEdge? in
            // §7.2's innermost-enclosing-closure rule (docs/task-closure-isolation-attribution.md):
            // if this call site falls inside a closure the project-wide accept-list recognizes
            // (Rule A/B/C), that closure's isolation -- not the declaration's own -- decides this
            // edge's risk. Nothing else about `edge.callerUSR`'s declaration changes: the node
            // entry below and every *other* edge from the same declaration still resolve through
            // `engine.resolveIsolation(for:)` untouched (§7.4's invariant).
            let declaredCallerIsolation = engine.resolveIsolation(for: edge.callerUSR)
            let callerIsolation = closuresByFile[edge.location.file].flatMap {
                effectiveCallerIsolation(atLine: edge.location.line, column: edge.location.column, in: $0)
            } ?? declaredCallerIsolation
            let calleeIsolation = engine.resolveIsolation(for: edge.calleeUSR)
            guard declaredCallerIsolation != calleeIsolation || callerIsolation != calleeIsolation else { return nil }
            let structuralRiskValue = riskLevel(caller: callerIsolation, callee: calleeIsolation)
            let severityRationale = structuralRiskValue == .high
                ? preconcurrencyDowngradeReason(
                    calleeUSR: edge.calleeUSR, callerFile: edge.location.file, caller: callerIsolation, callee: calleeIsolation,
                    declarations: declarations, preconcurrencyImportedModulesByFile: preconcurrencyImportedModulesByFile
                )
                : nil
            let risk = severityRationale == nil ? structuralRiskValue : .medium
            // Issue #46: whether this exact call site is syntactically inside a real
            // `await <expr>` expression (`AwaitedCallSiteExtractor`, purely syntactic, no
            // project-wide classification needed unlike closures) -- informational only, never
            // changes `risk`. `.high` deliberately tracks migration debt ("a nonisolated
            // declaration has a call edge into isolated state"), regardless of whether that edge
            // is already correctly `await`-ed today -- confirmed against this project's own
            // golden-fixture ground truth (`CompiledDependencyCLITests.swift`'s Mechanism A: a
            // real, compiling, already-`await`-ed `nonisolated async` call into `@MainActor`
            // state is deliberately still `.high`, exactly the shape this field now surfaces
            // without touching risk). See the root README's "An honest caveat about risk".
            let isAwaited = (awaitedRangesByFile[edge.location.file] ?? []).contains {
                $0.contains(line: edge.location.line, column: edge.location.column)
            }
            // Orthogonal to `risk` (computed above, unchanged, still a pure function of the two
            // resolved `IsolationKind`s) -- whether either endpoint is a USR the compiled-
            // dependency oracle tried and failed to resolve, per
            // docs/task-compiled-dependency-isolation.md's binding requirement that "no idea"
            // must never be conflated with a confirmed risk.
            let isUnknown = unknownUSRs.contains(edge.callerUSR) || unknownUSRs.contains(edge.calleeUSR)
            // *Any* caller reaching a *confirmed* `.nonisolated` callee is never a risk, not even a
            // low one: `nonisolated` imposes no isolation requirement on its caller, so the call
            // needs no `await` and can never race, regardless of which actor the caller is isolated
            // to -- or whether the caller is itself nonisolated. Confirmed directly by compilation
            // (both a `@MainActor` class and a custom `actor` calling a plain nonisolated function:
            // zero diagnostics under `-strict-concurrency=complete`) -- found auditing the medium-
            // risk bucket against Project Iris, where this shape alone was ~48% of it. Suppressed
            // entirely rather than downgraded to a new "no risk" level, per the audit's own
            // conclusion: it isn't ambiguous, so it doesn't belong in the report at all. Left alone
            // when `isUnknown` -- an oracle-failed lookup that happened to default to `.nonisolated`
            // is a fallback under uncertainty, not a confirmed fact, so it must still surface, not
            // be silently treated as proven-safe.
            //
            // Issue #41 (Rule C): originally gated on `isIsolated(callerIsolation)` too, since a
            // nonisolated-caller/nonisolated-callee pair could never reach this point at all under
            // the pre-Rule-C edge set (both declared nonisolated -> same declared domain -> not
            // "crossing" -> excluded upstream, long before this carve-out). Once Rule C started
            // including edges whose *effective* (closure-corrected) caller isolation is
            // `.nonisolated` while the *declared* caller was isolated (e.g. a `DispatchQueue.global()
            // .async { }` inside an otherwise-`@MainActor` method, calling a genuinely nonisolated
            // function), that narrower gate no longer matched -- confirmed a real, would-have-
            // shipped regression via this exact real-corpus before/after diff (10 spurious new
            // `nonisolated -> nonisolated` "medium" edges on Project Iris, all real instances of
            // this shape). The carve-out's own reasoning already never depended on the caller being
            // isolated in the first place, so dropping that half of the condition is the correct
            // fix, not a new judgment call.
            if case .nonisolated = calleeIsolation, !isUnknown {
                return nil
            }
            // A callee that's a `let`-bound (always-immutable, never-computed) stored property is
            // never a real risk either, regardless of which two isolation domains are involved:
            // reading immutable state can't race. Confirmed directly by compilation -- a
            // `nonisolated` synchronous function reading a `let` stored property of an unrelated
            // `@MainActor` struct compiles with zero diagnostics, no `await` needed (found
            // auditing a real project's own high-risk edges, `IceCubesApp`'s `Language.isoCode`).
            // Suppressed entirely, mirroring the carve-out immediately above -- not ambiguous, so
            // it doesn't belong in the report at all. Left alone when `isUnknown`, same reasoning.
            if declarations[edge.calleeUSR]?.isImmutableStoredProperty == true, !isUnknown {
                return nil
            }
            // A callee that's an actor's *own* initializer is never a real risk either, regardless
            // of caller isolation: SE-0306's own text (`docs/isolation-rules.md` rule 3) grants an
            // isolated `self` to an actor's instance methods, properties, and subscripts --
            // initializers are conspicuously absent, and real Swift confirms it: constructing a
            // new actor instance never requires prior access to that (not-yet-existing) instance,
            // so no `await` is needed from any caller. Confirmed directly by compilation (`actor A
            // { init() {} }`, a `nonisolated` caller constructing `A()`: zero diagnostics under
            // `-strict-concurrency=complete`) -- found auditing a real project's own high-risk
            // edges, `WordPress-iOS`'s `StatsService`/`WordPressClient`/... initializers. Suppressed
            // entirely, mirroring the two carve-outs immediately above.
            if declarations[edge.calleeUSR]?.isActorInitializer == true, !isUnknown {
                return nil
            }
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
                isUnknown: isUnknown,
                isAwaited: isAwaited,
                structuralRisk: severityRationale == nil ? nil : structuralRiskValue,
                severityRationale: severityRationale
            )
        }

        // The edge loop above can reference a USR that has no entry in `declarations` at all
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
            edges: edges,
            escapeHatches: escapeHatches
        )
    }

    /// One `EscapeHatchFinding` per explicit escape hatch found on any declaration -- a single
    /// declaration can carry more than one (e.g. a `nonisolated(unsafe) var` that's also
    /// `@preconcurrency`), so this is a flat map, not a 1:1 mapping over `declarations`. Sorted by
    /// location for deterministic output, matching `nodes`' own `declarations.keys.sorted()`
    /// treatment -- `declarations.values` itself has no defined order.
    private static func escapeHatchFindings(
        from declarations: [String: DeclarationInfo], preconcurrencyImportedModulesByFile: [String: Set<String>]
    ) -> [EscapeHatchFinding] {
        let declarationFindings = declarations.values.flatMap { declaration -> [EscapeHatchFinding] in
            let location = declaration.location.map { AnalysisLocation(file: $0.file, line: $0.line) }
            var findings: [EscapeHatchFinding] = []
            if declaration.isNonisolatedUnsafe {
                findings.append(EscapeHatchFinding(
                    kind: .nonisolatedUnsafe, declarationUSR: declaration.usr, name: declaration.name,
                    isMutable: !declaration.isImmutableStoredProperty, location: location
                ))
            }
            if declaration.hasPreconcurrencyAttribute {
                findings.append(EscapeHatchFinding(
                    kind: .preconcurrencyDeclaration, declarationUSR: declaration.usr, name: declaration.name,
                    isMutable: nil, location: location
                ))
            }
            for conformance in declaration.conformances {
                if conformance.isUnchecked {
                    findings.append(EscapeHatchFinding(
                        kind: .uncheckedSendable, declarationUSR: declaration.usr, name: declaration.name,
                        // Deferred (design doc Step 3): whether this type actually has a mutable
                        // stored property is an unscoped member-list/property-wrapper/inheritance
                        // walk, not computed in v1.
                        isMutable: nil, location: location
                    ))
                }
                if conformance.isPreconcurrency {
                    findings.append(EscapeHatchFinding(
                        kind: .preconcurrencyConformance, declarationUSR: declaration.usr, name: declaration.name,
                        isMutable: nil, location: location
                    ))
                }
            }
            return findings
        }

        // A module-level fact, not a declaration -- no `DeclarationInfo` to iterate over, just the
        // per-file `@preconcurrency import` sets `DeclarationLinker.link()` already merged.
        // `declarationUSR: nil` (see `EscapeHatchFinding`'s own doc comment); `name` carries the
        // module name instead.
        // `line: 0` deliberately -- `LinkedAnalysis.preconcurrencyImportedModulesByFile` merges
        // every file's own imports into a `Set<String>` (the downgrade lookup below only ever
        // needs "is this module name present in this file's own import set at all," never a source
        // position), so an individual import statement's own line is already gone by this point.
        // Same convention this codebase already uses for "no exact location" elsewhere
        // (`AnalysisNode`'s own `file: "", line: 0` for an unlocatable declaration).
        let importFindings = preconcurrencyImportedModulesByFile.flatMap { file, moduleNames in
            moduleNames.map { moduleName in
                EscapeHatchFinding(
                    kind: .preconcurrencyImport, declarationUSR: nil, name: moduleName,
                    isMutable: nil, location: AnalysisLocation(file: file, line: 0)
                )
            }
        }

        return (declarationFindings + importFindings).sorted { lhs, rhs in
            if lhs.location?.file != rhs.location?.file { return (lhs.location?.file ?? "") < (rhs.location?.file ?? "") }
            if lhs.location?.line != rhs.location?.line { return (lhs.location?.line ?? 0) < (rhs.location?.line ?? 0) }
            if lhs.declarationUSR != rhs.declarationUSR { return (lhs.declarationUSR ?? "") < (rhs.declarationUSR ?? "") }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    /// `@preconcurrency` on the callee's own declaration -- or on its *containing type*, since a
    /// type-level attribute softens diagnostics for its own unannotated members too, including
    /// extension members (confirmed by a real `swiftc -swift-version 6` test,
    /// `docs/task-escape-hatch-and-preconcurrency-severity.md` Step 2) -- downgrades a
    /// structurally-`.high` edge's reported severity to `.medium`, matching SE-0337's own
    /// error-to-warning downgrade. Deliberately does **not** consult
    /// `ProtocolConformance.isPreconcurrency` -- SE-0423 confirms a `@preconcurrency` conformance
    /// only softens a one-time witness-checker diagnostic at the conformance site itself, never
    /// diagnostics for arbitrary calls to the conforming type's methods (the design doc's own
    /// correction, made after an earlier draft of this function got that wrong). Only ever called
    /// for a structurally-`.high` edge -- see that call site's own comment for why `.medium` isn't
    /// scoped the same way.
    private static func preconcurrencyDowngradeReason(
        calleeUSR: String, callerFile: String, caller: IsolationKind, callee: IsolationKind,
        declarations: [String: DeclarationInfo], preconcurrencyImportedModulesByFile: [String: Set<String>]
    ) -> String? {
        guard let declaration = declarations[calleeUSR] else { return nil }
        let reason: String
        if declaration.hasPreconcurrencyAttribute {
            reason = "\(declaration.name) is @preconcurrency-attributed"
        } else if let containingTypeUSR = declaration.containingTypeUSR,
                  let containingType = declarations[containingTypeUSR],
                  containingType.hasPreconcurrencyAttribute {
            reason = "\(containingType.name) is @preconcurrency-attributed"
        } else if let moduleName = declaration.moduleName,
                  preconcurrencyImportedModulesByFile[callerFile]?.contains(moduleName) == true {
            // Second, independent trigger (PR2, shape 4): the callee's own defining module (only
            // ever known for an externally/oracle-resolved declaration -- see
            // `DeclarationInfo.moduleName`'s own doc comment) is one the *caller's file* itself
            // `@preconcurrency import`-ed. Same SE-0337 mechanism as the declaration trigger above,
            // just scoped by import instead of by individual declaration/type.
            reason = "\(declaration.name)'s module \(moduleName) is @preconcurrency-imported in this file"
        } else {
            return nil
        }
        return "structurally high (\(describe(caller)) -> \(describe(callee))); downgraded to medium: \(reason)"
    }

    /// Presentation-only filter applied after `build()`, driven by the CLI's `--severity` option --
    /// never changes what was actually detected, only what a given invocation chooses to display.
    /// `nil` (no `--severity` given) returns `report` unchanged.
    ///
    /// An edge is kept if it meets the threshold (`.high` keeps only `.high`; `.medium` keeps
    /// `.high` and `.medium`; `.low` keeps everything) **or** if either side of it is uncertain
    /// (`isUnknown`, or an isolation string of `"unspecified"`) -- regardless of threshold.
    /// Filtering to a stricter severity must never be a way to accidentally hide a case the tool
    /// doesn't have confirmed information about; that's the same "never conflate uncertainty with
    /// a confirmed risk" principle `isUnknown` itself exists for (see the suppression comment in
    /// `build()` for the analogous reasoning in the opposite direction -- confirmed-safe edges are
    /// dropped unconditionally, but never-confirmed ones are never dropped).
    ///
    /// Only `edges` and `summary.crossActorBoundaries` change (the latter kept consistent with the
    /// filtered edge count, so the output is never self-contradictory). `nodes` stays complete --
    /// every analyzed declaration is still real and still analyzed regardless of which edges this
    /// view chooses to surface. `highRiskBoundaries` is unaffected by construction: `.high` edges
    /// are never filtered out at any threshold.
    static func filtered(_ report: AnalysisReport, minimumSeverity: RiskLevel?) -> AnalysisReport {
        guard let minimumSeverity else { return report }

        func isUncertain(_ edge: AnalysisEdge) -> Bool {
            edge.isUnknown || edge.callerIsolation == "unspecified" || edge.calleeIsolation == "unspecified"
        }
        func meetsThreshold(_ edge: AnalysisEdge) -> Bool {
            switch minimumSeverity {
            case .low: return true
            case .medium: return edge.risk == .medium || edge.risk == .high
            case .high: return edge.risk == .high
            }
        }

        let filteredEdges = report.edges.filter { meetsThreshold($0) || isUncertain($0) }
        let summary = AnalysisSummary(
            typesAnalyzed: report.summary.typesAnalyzed,
            actors: report.summary.actors,
            mainActorTypes: report.summary.mainActorTypes,
            unspecifiedIsolation: report.summary.unspecifiedIsolation,
            crossActorBoundaries: filteredEdges.count,
            highRiskBoundaries: report.summary.highRiskBoundaries
        )
        return AnalysisReport(
            schemaVersion: report.schemaVersion,
            toolVersion: report.toolVersion,
            swiftVersion: report.swiftVersion,
            ruleSetUsed: report.ruleSetUsed,
            summary: summary,
            nodes: report.nodes,
            edges: filteredEdges
        )
    }

    /// `--sort` is a presentation choice like `--severity`: `edges` otherwise carries whatever
    /// order `engine.callGraph` happened to produce them in (`build()` above), which is not a
    /// documented or guaranteed order. `nodes`/`summary` are untouched -- only edge order changes.
    static func sorted(_ report: AnalysisReport, by sort: EdgeSortOption?) -> AnalysisReport {
        guard let sort else { return report }

        let sortedEdges: [AnalysisEdge]
        switch sort {
        case .file:
            sortedEdges = report.edges.sorted {
                ($0.location.file, $0.location.line) < ($1.location.file, $1.location.line)
            }
        case .severity:
            func rank(_ risk: RiskLevel) -> Int {
                switch risk {
                case .high: return 0
                case .medium: return 1
                case .low: return 2
                }
            }
            sortedEdges = report.edges.sorted {
                let (lhsRank, rhsRank) = (rank($0.risk), rank($1.risk))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return ($0.location.file, $0.location.line) < ($1.location.file, $1.location.line)
            }
        }

        return AnalysisReport(
            schemaVersion: report.schemaVersion,
            toolVersion: report.toolVersion,
            swiftVersion: report.swiftVersion,
            ruleSetUsed: report.ruleSetUsed,
            summary: report.summary,
            nodes: report.nodes,
            edges: sortedEdges
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
    ///   Note: an isolated caller reaching a *confirmed* `.nonisolated` callee would fall through
    ///   to here, but `build()` suppresses that shape before it ever reaches an `AnalysisEdge` --
    ///   see the suppression comment there. This function stays a pure classifier of the two
    ///   `IsolationKind`s regardless, so its own unit tests still exercise that raw case.
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
            // A global actor is a singleton -- there's only ever one `MainActor`, so caller and
            // callee naming the *same* global actor describes one isolation domain, not a
            // boundary at all: no suspension point exists, and none is needed (confirmed reading
            // real `.low` app-code edges against Project Iris -- every one of them was exactly
            // this shape, and none had an `await` at its call site; issue #47). Scoped to
            // `.globalActor` specifically, not `.actor` too: this tool has no notion of actor
            // *instance* identity, only actor *type* name, so two `.actor(name: "Foo")` endpoints
            // could still be two distinct instances of `Foo` needing a real `await` between them
            // -- claiming otherwise would be an unconfirmed, potentially wrong safety claim, which
            // this project's guiding principle rules out.
            if case .globalActor = caller, caller == callee {
                return "caller and callee share the same isolation domain (\(describe(caller))) -- no suspension needed"
            }
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
