import Testing
import IsolationCore
import OutputFormat
import SyntaxAnalysis
@testable import swift_isolation_map

@Suite("AnalysisReportBuilder")
struct AnalysisReportBuilderTests {
    @Test("Risk heuristic: nonisolated caller reaching actor-isolated callee is high risk")
    func nonisolatedReachingActorIsHigh() {
        #expect(AnalysisReportBuilder.riskLevel(caller: .nonisolated, callee: .actor(name: "UserSession")) == .high)
        #expect(AnalysisReportBuilder.riskLevel(caller: .nonisolated, callee: .globalActor(name: "MainActor")) == .high)
    }

    @Test("Risk heuristic: both sides actor-isolated is low risk")
    func bothIsolatedIsLow() {
        #expect(AnalysisReportBuilder.riskLevel(caller: .actor(name: "A"), callee: .actor(name: "B")) == .low)
        #expect(AnalysisReportBuilder.riskLevel(caller: .globalActor(name: "MainActor"), callee: .actor(name: "B")) == .low)
        #expect(AnalysisReportBuilder.riskLevel(caller: .actor(name: "A"), callee: .globalActor(name: "MainActor")) == .low)
    }

    @Test("Risk heuristic: anything else cross-isolation defaults to medium")
    func everythingElseIsMedium() {
        #expect(AnalysisReportBuilder.riskLevel(caller: .unspecified, callee: .actor(name: "A")) == .medium)
        #expect(AnalysisReportBuilder.riskLevel(caller: .actor(name: "A"), callee: .nonisolated) == .medium)
        #expect(AnalysisReportBuilder.riskLevel(caller: .actor(name: "A"), callee: .unspecified) == .medium)
    }

    @Test("build(): full fixture -- summary counts, node isolation strings, edge risk levels")
    func buildProducesExpectedReport() {
        // usr:actor -- an actor type with one instance member (usr:actor.member).
        // usr:mainActor -- a MainActor-attributed type with one member (usr:mainActor.member).
        // usr:free -- a nonisolated free function.
        // Call graph: usr:free -> usr:actor.member (nonisolated reaching actor: high risk),
        // usr:actor.member -> usr:mainActor.member (actor reaching globalActor: low risk),
        // usr:free -> usr:external (an unresolved USR, not in `declarations`: exercises the
        // `unspecifiedIsolation` summary count).
        let actorType = DeclarationInfo(usr: "usr:actor", name: "UserSession", isActorType: true)
        let actorMember = DeclarationInfo(usr: "usr:actor.member", name: "refresh", containingTypeUSR: "usr:actor")
        let mainActorType = DeclarationInfo(usr: "usr:mainActor", name: "ViewController", explicitIsolation: .globalActor(name: "MainActor"))
        let mainActorMember = DeclarationInfo(usr: "usr:mainActor.member", name: "render", containingTypeUSR: "usr:mainActor")
        let freeFunction = DeclarationInfo(usr: "usr:free", name: "trigger", explicitIsolation: .nonisolated)

        let declarations: [String: DeclarationInfo] = [
            "usr:actor": actorType,
            "usr:actor.member": actorMember,
            "usr:mainActor": mainActorType,
            "usr:mainActor.member": mainActorMember,
            "usr:free": freeFunction
        ]
        let callGraph = [
            CallGraphEdge(callerUSR: "usr:free", calleeUSR: "usr:actor.member", location: SymbolLocation(file: "Trigger.swift", line: 10, column: 5)),
            CallGraphEdge(callerUSR: "usr:actor.member", calleeUSR: "usr:mainActor.member", location: SymbolLocation(file: "Session.swift", line: 20, column: 5)),
            CallGraphEdge(callerUSR: "usr:free", calleeUSR: "usr:external", location: SymbolLocation(file: "Trigger.swift", line: 11, column: 5))
        ]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        #expect(report.schemaVersion == AnalysisReportBuilder.schemaVersion)
        #expect(report.swiftVersion == "6.0")
        #expect(report.ruleSetUsed == "Swift60RuleSet")
        #expect(report.toolVersion == "0.1.0")
        // usr:external is referenced only by an edge, never declared -- synthesized as a node
        // in its own right (isolation "unspecified") so no edge points at a missing node.
        #expect(report.nodes.count == 6)
        let externalNode = report.nodes.first { $0.usr == "usr:external" }
        #expect(externalNode?.isolation == "unspecified")

        let actorNode = report.nodes.first { $0.usr == "usr:actor" }
        #expect(actorNode?.isolation == "actor(UserSession)")
        let mainActorMemberNode = report.nodes.first { $0.usr == "usr:mainActor.member" }
        #expect(mainActorMemberNode?.isolation == "globalActor(MainActor)")

        // Both cross-isolation edges (free->actor.member, actor.member->mainActor.member) show
        // up; free->external is dropped by `crossIsolationEdges()` only if both sides resolve to
        // the *same* isolation -- an unresolved USR resolves to `.unspecified`, which differs
        // from `.nonisolated`, so it's still a cross-isolation edge here (medium risk).
        #expect(report.edges.count == 3)
        let highEdge = report.edges.first { $0.callerUSR == "usr:free" && $0.calleeUSR == "usr:actor.member" }
        #expect(highEdge?.risk == .high)
        let lowEdge = report.edges.first { $0.callerUSR == "usr:actor.member" && $0.calleeUSR == "usr:mainActor.member" }
        #expect(lowEdge?.risk == .low)
        let mediumEdge = report.edges.first { $0.calleeUSR == "usr:external" }
        #expect(mediumEdge?.risk == .medium)

        #expect(report.summary.actors == 1)
        #expect(report.summary.mainActorTypes == 1)
        #expect(report.summary.crossActorBoundaries == 3)
        #expect(report.summary.highRiskBoundaries == 1)
        // usr:free and usr:actor.member are both real, known declarations (never unspecified);
        // usr:external is the one call-graph endpoint outside the analyzed set.
        #expect(report.summary.unspecifiedIsolation == 1)
    }

    @Test("unknownUSRs: an edge whose raw risk would be high is excluded from highRiskBoundaries, but still counted and still marked isUnknown")
    func unknownEdgeExcludedFromHighRiskBoundaries() throws {
        // `usr:free` resolves to a real, known `.nonisolated` (not `.unspecified` -- this
        // specifically models the compiled-dependency oracle's declaration-level-trigger-failure
        // case, docs/priority-3-phase-c-oracle-triggers.md: the *triggering* declaration itself
        // still has a real project-local `DeclarationInfo`, resolved via the engine's own
        // existing default fallback, even when the external chain it depends on never got
        // resolved -- unlike an edge-level failure, where the unresolved USR has no
        // `DeclarationInfo` at all and resolves to `.unspecified`, naturally excluding it from
        // `.high` by construction). `usr:actor` genuinely resolves `.actor` -- so the edge's *raw*
        // `riskLevel(caller: .nonisolated, callee: .actor(...))` is `.high`, exactly the case the
        // `unknownUSRs` exclusion exists to keep out of `highRiskBoundaries`.
        let freeFunction = DeclarationInfo(usr: "usr:free", name: "trigger", explicitIsolation: .nonisolated)
        let actorType = DeclarationInfo(usr: "usr:actor", name: "UserSession", isActorType: true)
        let declarations: [String: DeclarationInfo] = ["usr:free": freeFunction, "usr:actor": actorType]
        let callGraph = [CallGraphEdge(callerUSR: "usr:free", calleeUSR: "usr:actor", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            unknownUSRs: ["usr:free"]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .high, "the raw risk classification is untouched -- isUnknown is an orthogonal marker, not a risk override")
        #expect(edge.isUnknown)
        #expect(report.summary.crossActorBoundaries == 1, "still counted as a cross-isolation boundary")
        #expect(report.summary.highRiskBoundaries == 0, "but excluded from highRiskBoundaries -- never conflated with a confirmed risk")
    }

    // MARK: - Closure isolation attribution (docs/task-closure-isolation-attribution.md, issue #33)

    private func closureFixtureEngine() -> (engine: IsolationInferenceEngine, edgeLocation: SymbolLocation) {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        return (IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet()), location)
    }

    @Test("A call directly inside Task { @MainActor in } is protected: risk drops from high to low")
    func callDirectlyInsideRecognizedClosureIsProtected() throws {
        let (engine, location) = closureFixtureEngine()
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .globalActor(name: "MainActor"))]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .low)
        #expect(edge.callerIsolation == "globalActor(MainActor)")
    }

    @Test("A call inside a plain (unrecognized) closure nested inside Task { @MainActor in } is NOT protected -- the §7.2 innermost-closure regression test")
    func callInsideUnrecognizedInnerClosureIsNotProtectedByOuterOne() throws {
        let (engine, location) = closureFixtureEngine()
        // Outer: Task { @MainActor in ... }, lines 1-10. Inner: DispatchQueue.global().async { ... },
        // lines 4-6, unrecognized (nil override) -- exactly the design doc's own §7.2 example.
        let closures = [
            ClassifiedClosure(startLine: 1, startColumn: 1, endLine: 10, endColumn: 1, isolationOverride: .globalActor(name: "MainActor")),
            ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: nil)
        ]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .high, "the innermost closure is unrecognized, so it must not inherit the outer closure's protection")
        #expect(edge.callerIsolation == "nonisolated")
    }

    @Test("A call inside Task { @MainActor in } targeting a *different* global actor is still reported -- the §7.4 invariant: substitute isolation, never skip the edge")
    func callInsideRecognizedClosureToADifferentActorIsStillReported() throws {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let otherActorCallee = DeclarationInfo(usr: "usr:callee", name: "onOther", explicitIsolation: .globalActor(name: "OtherActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": otherActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .globalActor(name: "MainActor"))]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first, "a skip-shaped implementation would have dropped this edge entirely instead of reclassifying it")
        #expect(edge.callerIsolation == "globalActor(MainActor)")
        #expect(edge.calleeIsolation == "globalActor(OtherActor)")
        #expect(edge.risk == .low, "both sides are isolated (to different actors), which is .low by the same heuristic used everywhere else -- not dropped, not high")
    }

    @Test("A call inside an unattributed Task { } is unaffected -- unrecognized closures never override, so behavior matches having no closure-tracking at all")
    func callInsideUnattributedTaskIsUnchanged() throws {
        // Caller declared @MainActor, callee isolated to a distinct actor -- a real cross-isolation
        // edge exists either way; what's under test is that the closure's nil override doesn't
        // perturb it (still resolves through the caller's own declared MainActor isolation).
        let mainActorCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .globalActor(name: "MainActor"))
        let otherActorCallee = DeclarationInfo(usr: "usr:callee", name: "onOther", explicitIsolation: .actor(name: "SomeActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": mainActorCaller, "usr:callee": otherActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: nil)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.callerIsolation == "globalActor(MainActor)", "falls back to the declaration's own resolved isolation, exactly as if no closure pass existed")
        #expect(edge.risk == .low)
    }

    @Test("DispatchQueue.main.async vs DispatchQueue.global().async on identical caller/callee shapes produce opposite risk outcomes")
    func dispatchMainVsGlobalProduceOppositeOutcomes() throws {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": mainActorCallee]
        let mainLocation = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let globalLocation = SymbolLocation(file: "Widget.swift", line: 15, column: 5)
        let callGraph = [
            CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: mainLocation),
            CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: globalLocation)
        ]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let closures = [
            ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .globalActor(name: "MainActor")),
            ClassifiedClosure(startLine: 14, startColumn: 1, endLine: 16, endColumn: 1, isolationOverride: nil)
        ]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [mainLocation.file: closures]
        )

        let mainEdge = try #require(report.edges.first { $0.location.line == mainLocation.line })
        let globalEdge = try #require(report.edges.first { $0.location.line == globalLocation.line })
        #expect(mainEdge.risk == .low)
        #expect(globalEdge.risk == .high)
    }
}
