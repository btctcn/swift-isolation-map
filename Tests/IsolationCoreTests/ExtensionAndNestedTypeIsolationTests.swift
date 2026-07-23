import Testing
@testable import IsolationCore

/// Gap C1/C2 from docs/isolation-rules.md — each test cites the specific empirical/proposal
/// evidence it verifies.

@Test("SE-0316: a global actor attribute on an extension isolates only that extension's members, independent of the primary type")
func extensionAttributeIsolatesOnlyItsOwnMembers() {
    let type = DeclarationInfo(usr: "s:type", name: "Plain")
    let primaryMember = DeclarationInfo(usr: "s:primary", name: "primaryMethod", containingTypeUSR: "s:type")
    let extensionMember = DeclarationInfo(
        usr: "s:extMember",
        name: "extensionMethod",
        containingTypeUSR: "s:type",
        enclosingExtensionIsolation: .globalActor(name: "MainActor")
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type, "s:primary": primaryMember, "s:extMember": extensionMember],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:primary") == .nonisolated)
    #expect(engine.resolveIsolation(for: "s:extMember") == .globalActor(name: "MainActor"))
}

@Test("An explicit attribute on the member itself still wins over its enclosing extension's attribute")
func explicitMemberAttributeBeatsEnclosingExtension() {
    let type = DeclarationInfo(usr: "s:type", name: "Plain")
    let member = DeclarationInfo(
        usr: "s:member",
        name: "explicitlyNonisolated",
        explicitIsolation: .nonisolated,
        containingTypeUSR: "s:type",
        enclosingExtensionIsolation: .globalActor(name: "MainActor")
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type, "s:member": member],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:member") == .nonisolated)
}

@Test("An enclosing extension's attribute wins over the primary type's own global actor propagation")
func enclosingExtensionOverridesTypePropagation() {
    let type = DeclarationInfo(usr: "s:type", name: "Widget", explicitIsolation: .globalActor(name: "MainActor"))
    let member = DeclarationInfo(
        usr: "s:member",
        name: "nonisolatedInExtension",
        containingTypeUSR: "s:type",
        enclosingExtensionIsolation: .nonisolated
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:type": type, "s:member": member],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:member") == .nonisolated)
}

@Test("A nested type inside an actor does NOT inherit actor isolation the way an instance member would")
func nestedTypeInsideActorDoesNotInheritActorIsolation() {
    let actorType = DeclarationInfo(usr: "s:actor", name: "UserSession", isActorType: true)
    let nested = DeclarationInfo(usr: "s:nested", name: "Snapshot", containingTypeUSR: "s:actor", isNestedType: true)
    let engine = IsolationInferenceEngine(
        declarations: ["s:actor": actorType, "s:nested": nested],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:nested") == .nonisolated)
}

@Test("A nested type inside a @MainActor class does NOT inherit that isolation via containing-type propagation")
func nestedTypeInsideGlobalActorClassDoesNotInheritViaPropagation() {
    let outer = DeclarationInfo(usr: "s:outer", name: "ProfileViewModel", explicitIsolation: .globalActor(name: "MainActor"))
    let nested = DeclarationInfo(usr: "s:nested", name: "State", containingTypeUSR: "s:outer", isNestedType: true)
    let engine = IsolationInferenceEngine(
        declarations: ["s:outer": outer, "s:nested": nested],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:nested") == .nonisolated)
}

@Test("SE-0466: a nested type IS eligible for the module default when its enclosing type does not resolve to nonisolated -- via the default tier, not inheritance")
func nestedTypeUsesModuleDefaultWhenEnclosingTypeIsIsolated() {
    // Deliberately different global actor names for outer vs. the configured default, to prove
    // the nested type picks up the *rule set's default*, not the container's own isolation --
    // confirming the mechanism is tier 4 (default), not tier 3 (containing-type propagation).
    let outer = DeclarationInfo(usr: "s:outer", name: "Coordinator", explicitIsolation: .globalActor(name: "CustomActor"))
    let nested = DeclarationInfo(usr: "s:nested", name: "State", containingTypeUSR: "s:outer", isNestedType: true)
    let engine = IsolationInferenceEngine(
        declarations: ["s:outer": outer, "s:nested": nested],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:nested") == .globalActor(name: "MainActor"))
}

@Test("SE-0466: a nested type inside an explicitly nonisolated enclosing type stays nonisolated even with a module default configured")
func nestedTypeStaysNonisolatedWhenEnclosingTypeIsNonisolated() {
    let outer = DeclarationInfo(usr: "s:outer", name: "PlainOuter", explicitIsolation: .nonisolated)
    let nested = DeclarationInfo(usr: "s:nested", name: "State", containingTypeUSR: "s:outer", isNestedType: true)
    let engine = IsolationInferenceEngine(
        declarations: ["s:outer": outer, "s:nested": nested],
        callGraph: [],
        ruleSet: Swift62RuleSet(defaultIsolation: .globalActor(name: "MainActor"))
    )
    #expect(engine.resolveIsolation(for: "s:nested") == .nonisolated)
}

@Test("A nested type's own superclass/conformance-based isolation still applies -- nesting only skips containing-type propagation, not the type's own hierarchy")
func nestedTypeStillInheritsFromItsOwnSuperclass() {
    let base = DeclarationInfo(usr: "s:base", name: "BaseState", explicitIsolation: .globalActor(name: "MainActor"))
    let outer = DeclarationInfo(usr: "s:outer", name: "Coordinator", explicitIsolation: .globalActor(name: "CustomActor"))
    let nested = DeclarationInfo(
        usr: "s:nested",
        name: "DerivedState",
        containingTypeUSR: "s:outer",
        superclassUSR: "s:base",
        isNestedType: true
    )
    let engine = IsolationInferenceEngine(
        declarations: ["s:base": base, "s:outer": outer, "s:nested": nested],
        callGraph: [],
        ruleSet: Swift60RuleSet()
    )
    #expect(engine.resolveIsolation(for: "s:nested") == .globalActor(name: "MainActor"))
}
