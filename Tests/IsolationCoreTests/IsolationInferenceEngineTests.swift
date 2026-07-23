import Testing
@testable import IsolationCore

/// Each test cites the exact swift-evolution wording it verifies — see docs/isolation-rules.md
/// for the full checklist and empirical (real-swiftc) validation notes.

@Test("SE-0306/SE-0316: explicit attribute always wins, even inside an actor")
func explicitAttributeOverridesContainingActor() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let member = DeclarationInfo(
        usr: "s:member",
        name: "cachedFlag",
        explicitIsolation: .nonisolated,
        containingTypeUSR: "s:actor"
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:actor": actorType, "s:member": member],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:member") == .nonisolated)
}

@Test("SE-0306: instance members of an actor have an isolated self by default")
func actorInstanceMemberInheritsActorIsolation() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let member = DeclarationInfo(usr: "s:member", name: "currentUser", containingTypeUSR: "s:actor")
    let engine = IsolationInferenceEngine(
        declarations: ["s:actor": actorType, "s:member": member],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:member") == .actor(name: "UserSession"))
}

@Test("SE-0306: static members of an actor are excluded from actor-instance isolation")
func actorStaticMemberIsNotActorIsolated() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let staticMember = DeclarationInfo(
        usr: "s:static",
        name: "shared",
        containingTypeUSR: "s:actor",
        isStaticMember: true
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:actor": actorType, "s:static": staticMember],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:static") == .nonisolated)
}

@Test("SE-0316: a type carrying a global actor attribute propagates it to instance methods")
func globalActorTypePropagatesToInstanceMember() {
    let type = DeclarationInfo(usr: "s:type", name: "ProfileViewModel", explicitIsolation: .globalActor(name: "MainActor"))
    let member = DeclarationInfo(usr: "s:member", name: "refresh", containingTypeUSR: "s:type")
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type, "s:member": member],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:member") == .globalActor(name: "MainActor"))
}

@Test("SE-0316: global actor propagation includes static members, unlike actor-instance isolation")
func globalActorTypePropagatesToStaticMemberToo() {
    let type = DeclarationInfo(usr: "s:type", name: "ProfileViewModel", explicitIsolation: .globalActor(name: "MainActor"))
    let staticMember = DeclarationInfo(
        usr: "s:static",
        name: "shared",
        containingTypeUSR: "s:type",
        isStaticMember: true
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type, "s:static": staticMember],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:static") == .globalActor(name: "MainActor"))
}

@Test("SE-0316: a class mandatorily inherits its superclass's global actor isolation")
func subclassMandatorilyInheritsSuperclassGlobalActor() {
    let base = DeclarationInfo(usr: "s:base", name: "BaseViewModel", explicitIsolation: .globalActor(name: "MainActor"))
    let derived = DeclarationInfo(usr: "s:derived", name: "DetailViewModel", superclassUSR: "s:base")
    let derivedMember = DeclarationInfo(usr: "s:derivedMember", name: "load", containingTypeUSR: "s:derived")
    let engine = IsolationInferenceEngine(
        declarations: ["s:base": base, "s:derived": derived, "s:derivedMember": derivedMember],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:derived") == .globalActor(name: "MainActor"))
    #expect(engine.resolveIsolation(for: "s:derivedMember") == .globalActor(name: "MainActor"))
}

@Test("SE-0316: conformance to a global-actor-qualified protocol in the same file infers whole-type isolation")
func sameFileProtocolConformanceInfersWholeTypeIsolation() {
    let type = DeclarationInfo(
        usr: "s:type",
        name: "SyncCoordinator",
        conformances: [
            ProtocolConformance(
                protocolUSR: "s:proto",
                protocolGlobalActorName: "MainActor",
                declaredInSameFileAsPrimaryDefinition: true,
                declaredInSameContextAsWitness: false
            )
        ]
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:type") == .globalActor(name: "MainActor"))
}

@Test("SE-0316: conformance declared in a different file does NOT infer whole-type isolation")
func differentFileProtocolConformanceDoesNotInferWholeTypeIsolation() {
    let type = DeclarationInfo(
        usr: "s:type",
        name: "SyncCoordinator",
        conformances: [
            ProtocolConformance(
                protocolUSR: "s:proto",
                protocolGlobalActorName: "MainActor",
                declaredInSameFileAsPrimaryDefinition: false,
                declaredInSameContextAsWitness: false
            )
        ]
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:type") == .nonisolated)
}

@Test("SE-0316: a witness still infers isolation per-member when its conformance is stated in the same extension")
func perWitnessInferenceAppliesEvenWithoutWholeTypeInference() {
    let witness = DeclarationInfo(
        usr: "s:witness",
        name: "encode(to:)",
        conformances: [
            ProtocolConformance(
                protocolUSR: "s:proto",
                protocolGlobalActorName: "MainActor",
                declaredInSameFileAsPrimaryDefinition: false,
                declaredInSameContextAsWitness: true
            )
        ]
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:witness": witness],
        callGraph: [],
        ruleSet: Swift6RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:witness") == .globalActor(name: "MainActor"))
}

@Test("SE-0466: Swift 5/6 rule sets never apply a default MainActor isolation")
func swift5And6NeverDefaultToMainActor() {
    let freeFunction = DeclarationInfo(usr: "s:fn", name: "process")
    let engineSwift5 = IsolationInferenceEngine(declarations: ["s:fn": freeFunction], callGraph: [], ruleSet: Swift5RuleSet())
    let engineSwift6 = IsolationInferenceEngine(declarations: ["s:fn": freeFunction], callGraph: [], ruleSet: Swift6RuleSet())
    #expect(engineSwift5.resolveIsolation(for: "s:fn") == .nonisolated)
    #expect(engineSwift6.resolveIsolation(for: "s:fn") == .nonisolated)
}

@Test("SE-0466: with no -default-isolation flag configured, Swift 6.2 still defaults to nonisolated")
func swift62DefaultsToNonisolatedWithoutExplicitOptIn() {
    let freeFunction = DeclarationInfo(usr: "s:fn", name: "process")
    let engine = IsolationInferenceEngine(declarations: ["s:fn": freeFunction], callGraph: [], ruleSet: Swift62RuleSet())
    #expect(engine.resolveIsolation(for: "s:fn") == .nonisolated)
}

@Test("SE-0466: an eligible declaration defaults to MainActor once the module opts in")
func swift62DefaultsToMainActorWhenConfigured() {
    let type = DeclarationInfo(usr: "s:type", name: "ViewState")
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:type") == .globalActor(name: "MainActor"))
}

@Test("SE-0466: declarations excluded from default-isolation (e.g. enum cases) stay nonisolated even with MainActor default configured")
func nonEligibleDeclarationIgnoresConfiguredDefault() {
    let enumCase = DeclarationInfo(usr: "s:case", name: "loading", isEligibleForModuleDefaultIsolation: false)
    let engine = IsolationInferenceEngine(
        declarations: ["s:case": enumCase],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:case") == .nonisolated)
}

@Test("SE-0466: inherited actor isolation takes priority over the module default, even inside an actor type")
func inheritedActorIsolationBeatsConfiguredDefault() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let member = DeclarationInfo(usr: "s:member", name: "currentUser", containingTypeUSR: "s:actor")
    let engine = IsolationInferenceEngine(
        declarations: ["s:actor": actorType, "s:member": member],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:member") == .actor(name: "UserSession"))
}

@Test(
    """
    SE-0466: 'declarations with inferred actor isolation from ... protocol conformance ... \
    default isolation does not apply' — a same-file conformance to a non-MainActor global actor \
    protocol beats the configured MainActor default, correcting the architecture spec's original \
    'default before protocol conformance' priority sketch.
    """
)
func protocolConformanceInferenceBeatsConfiguredDefault() {
    let type = DeclarationInfo(
        usr: "s:type",
        name: "BackgroundIndexer",
        conformances: [
            ProtocolConformance(
                protocolUSR: "s:proto",
                protocolGlobalActorName: "IndexerActor",
                declaredInSameFileAsPrimaryDefinition: true,
                declaredInSameContextAsWitness: false
            )
        ]
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:type") == .globalActor(name: "IndexerActor"))
}

@Test("crossIsolationEdges flags edges between differently-isolated declarations")
func crossIsolationEdgesFiltersMismatchedIsolation() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let member = DeclarationInfo(usr: "s:member", name: "currentUser", containingTypeUSR: "s:actor")
    let caller = DeclarationInfo(usr: "s:caller", name: "OrderProcessor")
    let sameIsolationCaller = DeclarationInfo(usr: "s:sameActorCaller", name: "sync", containingTypeUSR: "s:actor")

    let engine = IsolationInferenceEngine(
        declarations: [
            "s:actor": actorType,
            "s:member": member,
            "s:caller": caller,
            "s:sameActorCaller": sameIsolationCaller
        ],
        callGraph: [
            CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:member", location: SymbolLocation(file: "OrderProcessor.swift", line: 10, column: 1)),
            CallGraphEdge(callerUSR: "s:sameActorCaller", calleeUSR: "s:member", location: SymbolLocation(file: "UserSession.swift", line: 20, column: 1))
        ],
        ruleSet: Swift6RuleSet()
    )

    let flagged = engine.crossIsolationEdges()
    #expect(flagged.count == 1)
    #expect(flagged.first?.callerUSR == "s:caller")
}

@Test("An unknown USR resolves to .unspecified rather than crashing — honest uncertainty, not a guess")
func unknownUSRResolvesToUnspecified() {
    let engine = IsolationInferenceEngine(declarations: [:], callGraph: [], ruleSet: Swift6RuleSet())
    #expect(engine.resolveIsolation(for: "s:doesNotExist") == .unspecified)
}
