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

    // MARK: - Rule C (issue #41): the mirror, de-isolating direction

    @Test("A call inside Task.detached { }, declared inside a @MainActor method, is reported as high risk -- before Rule C, this was silently unprotected: the enclosing declaration's own MainActor isolation would have wrongly \"protected\" it")
    func callInsideTaskDetachedInsideMainActorMethodIsHighRisk() throws {
        let mainActorCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .globalActor(name: "MainActor"))
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": mainActorCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        // Task.detached { } itself, lines 4-6, classified nonisolated by Rule C.
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .nonisolated)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.callerIsolation == "nonisolated")
        #expect(edge.risk == .high)
    }

    @Test("A call inside DispatchQueue.global().async { }, declared inside a @MainActor method, is reported as high risk -- the same real gap Rule C closes, non-Task.detached form")
    func callInsideNonMainDispatchQueueInsideMainActorMethodIsHighRisk() throws {
        let mainActorCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .globalActor(name: "MainActor"))
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": mainActorCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .nonisolated)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.callerIsolation == "nonisolated")
        #expect(edge.risk == .high)
    }

    @Test("A call inside DispatchQueue.global().async { }, declared inside a @MainActor method, targeting a confirmed nonisolated callee, is suppressed entirely -- real regression caught via Project Iris before/after diff: the nonisolated-callee carve-out must key off the *effective* (closure-corrected) caller isolation, not just whether the caller happens to also be nonisolated")
    func callInsideNonMainDispatchQueueToNonisolatedCalleeIsSuppressed() {
        let mainActorCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .globalActor(name: "MainActor"))
        let nonisolatedCallee = DeclarationInfo(usr: "usr:callee", name: "runPerformanceTests", explicitIsolation: .nonisolated)
        let declarations: [String: DeclarationInfo] = ["usr:caller": mainActorCaller, "usr:callee": nonisolatedCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .nonisolated)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        #expect(report.edges.isEmpty, "calling a confirmed nonisolated function is always safe, regardless of whether the caller is isolated, effectively nonisolated via Rule C, or both -- must never be reported at all")
    }

    // MARK: - Isolated-caller-reaching-confirmed-nonisolated-callee suppression

    @Test("An isolated caller (actor or globalActor) reaching a confirmed nonisolated callee is suppressed entirely, not reported as medium")
    func isolatedCallerReachingConfirmedNonisolatedCalleeIsSuppressed() {
        let actorCaller = DeclarationInfo(usr: "usr:actorCaller", name: "trigger", isActorType: true)
        let mainActorCaller = DeclarationInfo(usr: "usr:mainActorCaller", name: "render", explicitIsolation: .globalActor(name: "MainActor"))
        let plainCallee = DeclarationInfo(usr: "usr:plain", name: "log", explicitIsolation: .nonisolated)
        let declarations: [String: DeclarationInfo] = [
            "usr:actorCaller": actorCaller,
            "usr:mainActorCaller": mainActorCaller,
            "usr:plain": plainCallee
        ]
        let callGraph = [
            CallGraphEdge(callerUSR: "usr:actorCaller", calleeUSR: "usr:plain", location: SymbolLocation(file: "T.swift", line: 1, column: 1)),
            CallGraphEdge(callerUSR: "usr:mainActorCaller", calleeUSR: "usr:plain", location: SymbolLocation(file: "T.swift", line: 2, column: 1))
        ]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        #expect(report.edges.isEmpty, "calling a confirmed nonisolated declaration is never a risk from any isolated context -- must not appear in the report at all")
        #expect(report.summary.crossActorBoundaries == 0)
    }

    @Test("The suppression does not apply when the nonisolated resolution is only an oracle-failure fallback (isUnknown)")
    func suppressionDoesNotApplyWhenCalleeIsolationIsUnknown() throws {
        let actorCaller = DeclarationInfo(usr: "usr:actorCaller", name: "trigger", isActorType: true)
        let plainCallee = DeclarationInfo(usr: "usr:plain", name: "log", explicitIsolation: .nonisolated)
        let declarations: [String: DeclarationInfo] = ["usr:actorCaller": actorCaller, "usr:plain": plainCallee]
        let callGraph = [CallGraphEdge(callerUSR: "usr:actorCaller", calleeUSR: "usr:plain", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            unknownUSRs: ["usr:plain"]
        )

        let edge = try #require(report.edges.first, "an oracle-failure fallback to .nonisolated is not a confirmed fact -- must still surface, not be silently treated as proven-safe")
        #expect(edge.isUnknown)
    }

    // MARK: - Actor-own-initializer callee suppression (WordPress-iOS audit finding)

    @Test("A callee that's an actor's own initializer is suppressed entirely, not reported as high risk, regardless of caller isolation")
    func actorOwnInitializerCalleeIsSuppressed() {
        // Real shape confirmed against WordPress-iOS: `nonisolated` code constructing a new
        // instance of a custom actor (`StatsService(...)`, `WordPressClient(...)`) was reported as
        // a high-risk `nonisolated -> actor(...)` boundary -- but SE-0306's own text (quoted in
        // docs/isolation-rules.md rule 3) grants an isolated `self` only to an actor's instance
        // methods, properties, and subscripts, never its initializer. Confirmed directly by
        // compilation: `actor A { init() {} }` constructed from a `nonisolated` function compiles
        // with zero diagnostics under `-strict-concurrency=complete`, no `await` needed.
        let actorType = DeclarationInfo(usr: "usr:actor", name: "StatsService", isActorType: true)
        let actorInit = DeclarationInfo(
            usr: "usr:actor.init", name: "init", containingTypeUSR: "usr:actor", isActorInitializer: true
        )
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "makeService", explicitIsolation: .nonisolated)
        let declarations: [String: DeclarationInfo] = [
            "usr:actor": actorType,
            "usr:actor.init": actorInit,
            "usr:caller": nonisolatedCaller
        ]
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:actor.init", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        #expect(report.edges.isEmpty, "constructing a new actor instance is never a risk from any caller isolation -- must not appear in the report at all")
        #expect(report.summary.crossActorBoundaries == 0)
    }

    @Test("The actor-initializer suppression does not apply when the callee resolution is only an oracle-failure fallback (isUnknown)")
    func actorInitializerSuppressionDoesNotApplyWhenCalleeIsolationIsUnknown() throws {
        let actorType = DeclarationInfo(usr: "usr:actor", name: "StatsService", isActorType: true)
        let actorInit = DeclarationInfo(
            usr: "usr:actor.init", name: "init", containingTypeUSR: "usr:actor", isActorInitializer: true
        )
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "makeService", explicitIsolation: .nonisolated)
        let declarations: [String: DeclarationInfo] = ["usr:actor": actorType, "usr:actor.init": actorInit, "usr:caller": nonisolatedCaller]
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:actor.init", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            unknownUSRs: ["usr:actor.init"]
        )

        let edge = try #require(report.edges.first, "an oracle-failure fallback is not a confirmed fact -- must still surface, not be silently treated as proven-safe")
        #expect(edge.isUnknown)
    }

    // MARK: - Low-risk explanation text accuracy (issue #47)

    @Test("Low risk, same global actor on both sides: explanation says 'same isolation domain', not 'compiler-enforced via await'")
    func lowRiskSameGlobalActorExplanationDoesNotClaimAwait() throws {
        // Reproduces the real shape found auditing Project Iris's own `.low` app-code edges
        // (docs/reference-project-corpora.md): `Task { @MainActor in AuthenticationService.shared.
        // userDidLogout() }` inside a caller whose own *declared* isolation is `.nonisolated` --
        // `crossIsolationEdges()` sees the call as crossing using that declared value (which is
        // why it's an edge at all), but the closure-attribution substitution (Rule A, #33) then
        // reports both sides as `.globalActor(MainActor)` for risk/explanation purposes. Verified
        // by reading the real source: no `await` at that call site at all -- same-actor calls
        // never need one, so asserting "compiler-enforced via await" here was simply false.
        let (engine, location) = closureFixtureEngine()
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .globalActor(name: "MainActor"))]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .low)
        #expect(edge.callerIsolation == edge.calleeIsolation)
        #expect(edge.explanation.contains("same isolation domain"))
        #expect(!edge.explanation.contains("await"))
    }

    @Test("Low risk, two different isolated domains: explanation still correctly says 'compiler-enforced via await'")
    func lowRiskDifferentDomainsExplanationStillClaimsAwait() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "refresh", isActorType: true)
        let callee = DeclarationInfo(usr: "usr:callee", name: "render", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": caller, "usr:callee": callee]
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .low)
        #expect(edge.explanation.contains("compiler-enforced via await"))
    }

    @Test("Low risk, effective caller and callee both resolve to the same custom actor name: still claims await (no instance-identity tracking, so this must stay conservative)")
    func lowRiskSameActorTypeNameStillClaimsAwait() throws {
        // Deliberately NOT the same fix as the globalActor case: this tool tracks actor isolation
        // by *type name* only, so two `.actor(name: "Cache")` endpoints are not provably the same
        // isolation domain the way a global actor's singleton semantics guarantee -- they could be
        // two distinct instances of `Cache` (or two distinct types that happen to share the literal
        // name in different modules) genuinely needing a real `await` between them. Uses the same
        // closure-substitution mechanism as the real `.globalActor` bug (issue #47) to reach an
        // edge with identical caller/callee isolation strings, but overridden to `.actor`, not
        // `.globalActor` -- claiming "no suspension needed" here would be an unconfirmed safety
        // claim this project's guiding principle rules out.
        let location = SymbolLocation(file: "Widget.swift", line: 5, column: 5)
        let closures = [ClassifiedClosure(startLine: 4, startColumn: 1, endLine: 6, endColumn: 1, isolationOverride: .actor(name: "Cache"))]
        // Declared caller isolation (`.nonisolated`) differs from the declared callee isolation
        // (`.actor(name: "Cache")`), so `crossIsolationEdges()` sees this as crossing; the closure
        // override then substitutes the *caller's* effective isolation to `.actor(name: "Cache")`
        // too, landing both sides on the identical string for `explanation()` to see.
        let declarations: [String: DeclarationInfo] = [
            "usr:caller": DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated),
            "usr:callee": DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .actor(name: "Cache"))
        ]
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            closuresByFile: [location.file: closures]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.callerIsolation == edge.calleeIsolation, "both sides must resolve to the identical .actor(name:) string for this test to exercise the intended scoping")
        #expect(edge.risk == .low)
        #expect(edge.explanation.contains("compiler-enforced via await"))
    }

    // MARK: - `isAwaited`, informational only (issue #46)

    @Test("A call site inside a real await expression is marked isAwaited, but risk is unchanged -- .high still means migration debt, awaited or not")
    func awaitedCallSiteIsMarkedButRiskIsUnchanged() throws {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 2, column: 11)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        // Reproduces `await onMain()` at line 2, starting column 5 (the `await` keyword itself)
        // through column 21 (end of the call) -- the call site at column 11 falls inside it.
        let awaited = [AwaitedRange(file: "Widget.swift", startLine: 2, startColumn: 5, endLine: 2, endColumn: 21)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            awaitedRangesByFile: ["Widget.swift": awaited]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.isAwaited)
        #expect(edge.risk == .high, "confirmed against this project's own golden-fixture ground truth (Mechanism A): a real, compiling, already-awaited nonisolated-async call into isolated state is deliberately still .high -- it tracks migration debt, not just unguarded races")
        #expect(report.summary.highRiskBoundaries == 1)
    }

    @Test("The same shape without an await at the call site is not marked isAwaited")
    func sameShapeWithoutAwaitIsNotMarkedAwaited() throws {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 2, column: 5)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())

        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(!edge.isAwaited)
        #expect(edge.risk == .high)
    }

    @Test("An await range in a different file never marks an edge in this file as awaited -- ranges are looked up per file, not globally")
    func awaitedRangeInADifferentFileDoesNotMarkThisEdge() throws {
        let nonisolatedCaller = DeclarationInfo(usr: "usr:caller", name: "trigger", explicitIsolation: .nonisolated)
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:caller": nonisolatedCaller, "usr:callee": mainActorCallee]
        let location = SymbolLocation(file: "Widget.swift", line: 2, column: 11)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let awaited = [AwaitedRange(file: "Other.swift", startLine: 2, startColumn: 5, endLine: 2, endColumn: 21)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            awaitedRangesByFile: ["Other.swift": awaited]
        )

        let edge = try #require(report.edges.first)
        #expect(!edge.isAwaited)
        #expect(edge.risk == .high)
    }

    @Test("isAwaited is set for medium/low edges too, not just high -- it's a pure syntactic fact about the call site, independent of risk")
    func isAwaitedIsSetRegardlessOfRiskLevel() throws {
        let mainActorCallee = DeclarationInfo(usr: "usr:callee", name: "onMain", explicitIsolation: .globalActor(name: "MainActor"))
        let declarations: [String: DeclarationInfo] = ["usr:callee": mainActorCallee]
        // "usr:caller" is deliberately absent from `declarations`, so it resolves to `.unspecified`
        // -- the existing medium-risk shape, unrelated to `.nonisolated`.
        let location = SymbolLocation(file: "Widget.swift", line: 2, column: 11)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: location)]
        let engine = IsolationInferenceEngine(declarations: declarations, callGraph: callGraph, ruleSet: Swift60RuleSet())
        let awaited = [AwaitedRange(file: "Widget.swift", startLine: 2, startColumn: 5, endLine: 2, endColumn: 21)]

        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            awaitedRangesByFile: ["Widget.swift": awaited]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.isAwaited)
        #expect(edge.risk == .medium, "isAwaited is orthogonal to risk -- it doesn't move a .medium edge to any other bucket")
    }

    // MARK: - `--severity` presentation filter (AnalysisReportBuilder.filtered)

    private func makeEdge(
        id: String, risk: RiskLevel,
        callerIsolation: String = "actor(A)", calleeIsolation: String = "actor(B)",
        isUnknown: Bool = false,
        location: AnalysisLocation = AnalysisLocation(file: "T.swift", line: 1)
    ) -> AnalysisEdge {
        AnalysisEdge(
            callerUSR: "usr:caller.\(id)", calleeUSR: "usr:callee.\(id)",
            callerIsolation: callerIsolation, calleeIsolation: calleeIsolation,
            risk: risk, explanation: "test edge \(id)",
            location: location, isUnknown: isUnknown
        )
    }

    private func makeReport(edges: [AnalysisEdge]) -> AnalysisReport {
        AnalysisReport(
            schemaVersion: "1.0", toolVersion: "0.1.0", swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet",
            summary: AnalysisSummary(typesAnalyzed: 0, actors: 0, mainActorTypes: 0, unspecifiedIsolation: 0, crossActorBoundaries: edges.count, highRiskBoundaries: edges.filter { $0.risk == .high }.count),
            nodes: [], edges: edges
        )
    }

    @Test("filtered(): nil severity (no --severity given) returns the report unchanged")
    func filteredWithNilSeverityIsIdentity() {
        let report = makeReport(edges: [makeEdge(id: "1", risk: .high), makeEdge(id: "2", risk: .medium), makeEdge(id: "3", risk: .low)])
        #expect(AnalysisReportBuilder.filtered(report, minimumSeverity: nil) == report)
    }

    @Test("filtered(): --severity high keeps only high-risk edges, plus any edge with unresolved/unknown isolation on either side")
    func filteredHighSeverityKeepsHighAndUncertain() {
        let highEdge = makeEdge(id: "high", risk: .high)
        let mediumEdge = makeEdge(id: "medium", risk: .medium)
        let lowEdge = makeEdge(id: "low", risk: .low)
        let unspecifiedCallerEdge = makeEdge(id: "unspecified", risk: .medium, callerIsolation: "unspecified")
        let unknownLowEdge = makeEdge(id: "unknown", risk: .low, isUnknown: true)
        let report = makeReport(edges: [highEdge, mediumEdge, lowEdge, unspecifiedCallerEdge, unknownLowEdge])

        let result = AnalysisReportBuilder.filtered(report, minimumSeverity: .high)

        #expect(result.edges.count == 3)
        #expect(result.edges.contains(highEdge))
        #expect(result.edges.contains(unspecifiedCallerEdge), "unresolved isolation must survive even the strictest filter")
        #expect(result.edges.contains(unknownLowEdge), "isUnknown must survive even the strictest filter, regardless of its own risk level")
        #expect(!result.edges.contains(mediumEdge))
        #expect(!result.edges.contains(lowEdge))
        #expect(result.summary.crossActorBoundaries == 3, "kept consistent with the filtered edge count")
        #expect(result.summary.highRiskBoundaries == report.summary.highRiskBoundaries, "unaffected by the presentation filter")
    }

    @Test("filtered(): --severity medium keeps high and medium, plus uncertain edges; drops confirmed low")
    func filteredMediumSeverityDropsOnlyConfirmedLow() {
        let highEdge = makeEdge(id: "high", risk: .high)
        let mediumEdge = makeEdge(id: "medium", risk: .medium)
        let lowEdge = makeEdge(id: "low", risk: .low)
        let unknownLowEdge = makeEdge(id: "unknown", risk: .low, isUnknown: true)
        let report = makeReport(edges: [highEdge, mediumEdge, lowEdge, unknownLowEdge])

        let result = AnalysisReportBuilder.filtered(report, minimumSeverity: .medium)

        #expect(result.edges.count == 3)
        #expect(result.edges.contains(highEdge))
        #expect(result.edges.contains(mediumEdge))
        #expect(result.edges.contains(unknownLowEdge))
        #expect(!result.edges.contains(lowEdge))
    }

    @Test("filtered(): --severity low keeps everything")
    func filteredLowSeverityKeepsEverything() {
        let report = makeReport(edges: [makeEdge(id: "1", risk: .high), makeEdge(id: "2", risk: .medium), makeEdge(id: "3", risk: .low)])
        #expect(AnalysisReportBuilder.filtered(report, minimumSeverity: .low).edges.count == 3)
    }

    // MARK: - `--sort` presentation ordering (AnalysisReportBuilder.sorted)

    @Test("sorted(): nil sort (no --sort given) returns the report unchanged")
    func sortedWithNilOptionIsIdentity() {
        let report = makeReport(edges: [makeEdge(id: "1", risk: .low), makeEdge(id: "2", risk: .high)])
        #expect(AnalysisReportBuilder.sorted(report, by: nil) == report)
    }

    @Test("sorted(): file orders edges by location.file, then by line within the same file")
    func sortedByFileOrdersByFileThenLine() {
        let b2 = makeEdge(id: "b2", risk: .low, location: AnalysisLocation(file: "B.swift", line: 2))
        let a1 = makeEdge(id: "a1", risk: .low, location: AnalysisLocation(file: "A.swift", line: 1))
        let b1 = makeEdge(id: "b1", risk: .low, location: AnalysisLocation(file: "B.swift", line: 1))
        let report = makeReport(edges: [b2, a1, b1])

        let result = AnalysisReportBuilder.sorted(report, by: .file)

        #expect(result.edges.map(\.callerUSR) == [a1, b1, b2].map(\.callerUSR))
    }

    @Test("sorted(): severity orders high before medium before low, then by location.file within the same risk")
    func sortedBySeverityOrdersHighFirst() {
        let low = makeEdge(id: "low", risk: .low, location: AnalysisLocation(file: "T.swift", line: 1))
        let mediumB = makeEdge(id: "mediumB", risk: .medium, location: AnalysisLocation(file: "B.swift", line: 1))
        let mediumA = makeEdge(id: "mediumA", risk: .medium, location: AnalysisLocation(file: "A.swift", line: 1))
        let high = makeEdge(id: "high", risk: .high, location: AnalysisLocation(file: "T.swift", line: 1))
        let report = makeReport(edges: [low, mediumB, mediumA, high])

        let result = AnalysisReportBuilder.sorted(report, by: .severity)

        #expect(result.edges.map(\.callerUSR) == [high, mediumA, mediumB, low].map(\.callerUSR))
    }

    @Test("sorted(): does not change summary or nodes, only edge order")
    func sortedLeavesSummaryAndNodesUnchanged() {
        let report = makeReport(edges: [makeEdge(id: "1", risk: .low), makeEdge(id: "2", risk: .high)])
        let result = AnalysisReportBuilder.sorted(report, by: .severity)
        #expect(result.summary == report.summary)
        #expect(result.nodes == report.nodes)
    }

    // MARK: - Escape hatches and @preconcurrency severity downgrade
    // (docs/task-escape-hatch-and-preconcurrency-severity.md)

    @Test("build(): a nonisolated(unsafe) property and an @unchecked Sendable conformance both produce EscapeHatchFinding entries")
    func buildProducesEscapeHatchFindingsForUnsafePropertyAndUncheckedConformance() {
        let widget = DeclarationInfo(
            usr: "usr:widget", name: "Widget",
            conformances: [ProtocolConformance(
                protocolUSR: "syntactic:Sendable", protocolGlobalActorName: nil,
                declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false, isUnchecked: true
            )]
        )
        let unsafeVar = DeclarationInfo(
            usr: "usr:widget.counter", name: "counter", containingTypeUSR: "usr:widget",
            isImmutableStoredProperty: false, isNonisolatedUnsafe: true
        )
        let engine = IsolationInferenceEngine(
            declarations: ["usr:widget": widget, "usr:widget.counter": unsafeVar], callGraph: [], ruleSet: Swift60RuleSet()
        )
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        #expect(report.escapeHatches.contains { $0.kind == .uncheckedSendable && $0.declarationUSR == "usr:widget" })
        #expect(report.escapeHatches.contains { $0.kind == .nonisolatedUnsafe && $0.declarationUSR == "usr:widget.counter" && $0.isMutable == true })
    }

    @Test("build(): a nonisolated(unsafe) let property is flagged with isMutable false")
    func buildFlagsNonisolatedUnsafeLetAsImmutable() {
        let unsafeLet = DeclarationInfo(usr: "usr:x", name: "x", isImmutableStoredProperty: true, isNonisolatedUnsafe: true)
        let engine = IsolationInferenceEngine(declarations: ["usr:x": unsafeLet], callGraph: [], ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")
        #expect(report.escapeHatches.contains { $0.kind == .nonisolatedUnsafe && $0.isMutable == false })
    }

    @Test("build(): a @preconcurrency-attributed declaration produces a .preconcurrencyDeclaration finding; an @preconcurrency-attributed conformance produces a separate .preconcurrencyConformance finding")
    func buildProducesPreconcurrencyFindingsForBothDeclarationAndConformance() {
        let annotatedFunc = DeclarationInfo(usr: "usr:f", name: "annotatedFunc", hasPreconcurrencyAttribute: true)
        let widget = DeclarationInfo(
            usr: "usr:widget", name: "Widget",
            conformances: [ProtocolConformance(
                protocolUSR: "syntactic:P", protocolGlobalActorName: nil,
                declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false, isPreconcurrency: true
            )]
        )
        let engine = IsolationInferenceEngine(declarations: ["usr:f": annotatedFunc, "usr:widget": widget], callGraph: [], ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        #expect(report.escapeHatches.contains { $0.kind == .preconcurrencyDeclaration && $0.declarationUSR == "usr:f" })
        #expect(report.escapeHatches.contains { $0.kind == .preconcurrencyConformance && $0.declarationUSR == "usr:widget" })
    }

    @Test("build(): a structurally-high edge whose callee is @preconcurrency-attributed is downgraded to medium, with structuralRisk/severityRationale recording the original value and reason")
    func buildDowngradesHighEdgeWhenCalleeHasPreconcurrencyAttribute() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let callee = DeclarationInfo(usr: "usr:callee", name: "callee", explicitIsolation: .globalActor(name: "MainActor"), hasPreconcurrencyAttribute: true)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: ["usr:caller": caller, "usr:callee": callee], callGraph: callGraph, ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .medium)
        #expect(edge.structuralRisk == .high)
        #expect(edge.severityRationale?.isEmpty == false)
    }

    @Test("build(): the downgrade also applies when the callee's containing type -- not the callee itself -- carries @preconcurrency (type-level propagation, confirmed by a real swiftc test)")
    func buildDowngradesHighEdgeWhenContainingTypeHasPreconcurrencyAttribute() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let containingType = DeclarationInfo(usr: "usr:AnnotatedType", name: "AnnotatedType", hasPreconcurrencyAttribute: true)
        let callee = DeclarationInfo(usr: "usr:callee", name: "method", explicitIsolation: .globalActor(name: "MainActor"), containingTypeUSR: "usr:AnnotatedType")
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(
            declarations: ["usr:caller": caller, "usr:AnnotatedType": containingType, "usr:callee": callee],
            callGraph: callGraph, ruleSet: Swift60RuleSet()
        )
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .medium)
        #expect(edge.structuralRisk == .high)
    }

    @Test("build(): a @preconcurrency-attributed CONFORMANCE on the callee's type never triggers the downgrade -- SE-0423 only softens the one-time witness-checker diagnostic, not arbitrary calls (regression guard for the mechanism this design doc's review caught and corrected)")
    func buildDoesNotDowngradeWhenOnlyConformanceIsPreconcurrencyAttributed() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let containingType = DeclarationInfo(
            usr: "usr:AnnotatedType", name: "AnnotatedType",
            conformances: [ProtocolConformance(
                protocolUSR: "syntactic:P", protocolGlobalActorName: nil,
                declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false, isPreconcurrency: true
            )]
        )
        let callee = DeclarationInfo(usr: "usr:callee", name: "method", explicitIsolation: .globalActor(name: "MainActor"), containingTypeUSR: "usr:AnnotatedType")
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(
            declarations: ["usr:caller": caller, "usr:AnnotatedType": containingType, "usr:callee": callee],
            callGraph: callGraph, ruleSet: Swift60RuleSet()
        )
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .high)
        #expect(edge.structuralRisk == nil)
        #expect(edge.severityRationale == nil)
    }

    @Test("build(): the downgrade never applies to a structurally-medium edge, even when the callee is @preconcurrency-attributed -- scoped deliberately to high -> medium only")
    func buildDoesNotDowngradeMediumEdgeEvenWithPreconcurrencyCallee() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .unspecified)
        let callee = DeclarationInfo(usr: "usr:callee", name: "callee", explicitIsolation: .actor(name: "A"), hasPreconcurrencyAttribute: true)
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "T.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: ["usr:caller": caller, "usr:callee": callee], callGraph: callGraph, ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0")

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .medium)
        #expect(edge.structuralRisk == nil)
        #expect(edge.severityRationale == nil)
    }

    // MARK: - PR2: `@preconcurrency import` (shape 4) -- second downgrade trigger, `.preconcurrencyImport` finding
    // (docs/task-escape-hatch-and-preconcurrency-severity.md)

    @Test("build(): a preconcurrencyImportedModulesByFile entry produces a .preconcurrencyImport EscapeHatchFinding with declarationUSR nil and the module name as its own name")
    func buildProducesPreconcurrencyImportFinding() {
        let engine = IsolationInferenceEngine(declarations: [:], callGraph: [], ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            preconcurrencyImportedModulesByFile: ["T.swift": ["WebKit"]]
        )
        let finding = try? #require(report.escapeHatches.first)
        #expect(finding?.kind == .preconcurrencyImport)
        #expect(finding?.declarationUSR == nil)
        #expect(finding?.name == "WebKit")
    }

    @Test("build(): a structurally-high edge whose callee's own module is @preconcurrency-imported in the caller's file is downgraded to medium, even though neither the callee nor its containing type carries @preconcurrency itself")
    func buildDowngradesHighEdgeViaPreconcurrencyImportTrigger() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let callee = DeclarationInfo(
            usr: "usr:callee", name: "reload", explicitIsolation: .globalActor(name: "MainActor"), moduleName: "WebKit"
        )
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "Caller.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: ["usr:caller": caller, "usr:callee": callee], callGraph: callGraph, ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            preconcurrencyImportedModulesByFile: ["Caller.swift": ["WebKit"]]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .medium)
        #expect(edge.structuralRisk == .high)
        #expect(edge.severityRationale?.contains("WebKit") == true)
    }

    @Test("build(): the import trigger does not fire when the caller's file imports a DIFFERENT module than the callee's own, even if some other file in the project imports the right one -- the import set is scoped per caller file, not project-wide")
    func buildDoesNotDowngradeWhenCallerFileImportsAnUnrelatedModule() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let callee = DeclarationInfo(
            usr: "usr:callee", name: "reload", explicitIsolation: .globalActor(name: "MainActor"), moduleName: "WebKit"
        )
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "Caller.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: ["usr:caller": caller, "usr:callee": callee], callGraph: callGraph, ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            // Caller's own file imports something, but not WebKit -- and a different file
            // importing WebKit @preconcurrency must not leak into this caller's own downgrade.
            preconcurrencyImportedModulesByFile: ["Caller.swift": ["Foundation"], "Other.swift": ["WebKit"]]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .high)
        #expect(edge.structuralRisk == nil)
    }

    @Test("build(): the import trigger does not fire for a callee with no known moduleName (a project-local declaration, never oracle-resolved)")
    func buildDoesNotDowngradeWhenCalleeHasNoModuleName() throws {
        let caller = DeclarationInfo(usr: "usr:caller", name: "caller", explicitIsolation: .nonisolated)
        let callee = DeclarationInfo(usr: "usr:callee", name: "callee", explicitIsolation: .globalActor(name: "MainActor"))
        let callGraph = [CallGraphEdge(callerUSR: "usr:caller", calleeUSR: "usr:callee", location: SymbolLocation(file: "Caller.swift", line: 1, column: 1))]
        let engine = IsolationInferenceEngine(declarations: ["usr:caller": caller, "usr:callee": callee], callGraph: callGraph, ruleSet: Swift60RuleSet())
        let report = AnalysisReportBuilder.build(
            engine: engine, swiftVersion: "6.0", ruleSetUsed: "Swift60RuleSet", toolVersion: "0.1.0",
            preconcurrencyImportedModulesByFile: ["Caller.swift": ["WebKit"]]
        )

        let edge = try #require(report.edges.first)
        #expect(edge.risk == .high)
        #expect(edge.structuralRisk == nil)
    }
}
