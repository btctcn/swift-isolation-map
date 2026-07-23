/// Resolves the actor isolation of every declaration in a project by combining explicit
/// attributes with structural inheritance and module-level defaults.
///
/// Resolution order (see docs/isolation-rules.md for the SE-proposal citation behind each step):
/// 1. Explicit isolation attribute on the declaration itself.
/// 2. A global actor attribute on the *enclosing extension* the declaration is physically
///    inside (SE-0316's second, independent propagation rule) — wins over the containing
///    type's own propagation, but not over an explicit attribute on the declaration itself.
/// 3. Isolation inherited from a containing actor/global-actor type (skipped entirely for
///    nested types — see below), a global-actor-isolated superclass, or a same-context
///    protocol conformance — resolved recursively, so a container that only reaches @MainActor
///    via the module default still propagates it to its members and subclasses.
/// 4. The rule set's module-level default isolation (SE-0466), only for declarations
///    untouched by 1-3 and eligible for defaulting. For a nested type specifically, eligibility
///    isn't the flat per-declaration fact used elsewhere — it's gated by whether the enclosing
///    type's own resolved isolation is nonisolated (see docs/isolation-rules.md, Gap C2).
/// 5. `.nonisolated` as the final fallback.
///
/// Note this reorders the architecture spec's original "default before protocol conformance"
/// sketch: SE-0466 explicitly excludes from default-isolation any declaration with "inferred
/// actor isolation from a superclass, overridden method, protocol conformance, or member
/// propagation" — inheritance must be resolved before the default is even considered.
///
/// Nested types are deliberately not treated as "just another member": SE-0316's type->members
/// propagation does not extend to nested type declarations (confirmed empirically — a nested
/// type inside an `actor` or a `@MainActor` class does not inherit that isolation the way an
/// instance method would). Naively reusing the containing-type-propagation branch for them
/// would produce a wrong answer, not just an incomplete one.
public final class IsolationInferenceEngine {
    public let declarations: [String: DeclarationInfo]
    public let callGraph: [CallGraphEdge]
    public let ruleSet: IsolationRuleSet

    public init(declarations: [String: DeclarationInfo], callGraph: [CallGraphEdge], ruleSet: IsolationRuleSet) {
        self.declarations = declarations
        self.callGraph = callGraph
        self.ruleSet = ruleSet
    }

    public func resolveIsolation(for usr: String) -> IsolationKind {
        guard let declaration = declarations[usr] else { return .unspecified }
        return resolveIsolation(for: declaration, visiting: [])
    }

    public func crossIsolationEdges() -> [CallGraphEdge] {
        callGraph.filter { edge in
            resolveIsolation(for: edge.callerUSR) != resolveIsolation(for: edge.calleeUSR)
        }
    }

    private func resolveIsolation(for declaration: DeclarationInfo, visiting: Set<String>) -> IsolationKind {
        // Guards against a malformed/cyclic fixture (or, later, malformed real project data)
        // recursing forever — honest "don't know" beats a crash or a wrong guess.
        guard !visiting.contains(declaration.usr) else { return .unspecified }
        var visiting = visiting
        visiting.insert(declaration.usr)

        // SE-0306: an actor type is isolated to itself — this is the base fact the whole
        // model of actor isolation is built on, not something layered on top via an attribute.
        if declaration.isActorType {
            return .actor(name: declaration.name)
        }
        if let explicit = declaration.explicitIsolation {
            return explicit
        }
        if let enclosingExtensionIsolation = declaration.enclosingExtensionIsolation {
            return enclosingExtensionIsolation
        }
        if let inherited = resolveInheritedIsolation(for: declaration, visiting: visiting) {
            return inherited
        }
        return resolveDefaultIsolation(for: declaration, visiting: visiting)
    }

    private func resolveInheritedIsolation(for declaration: DeclarationInfo, visiting: Set<String>) -> IsolationKind? {
        // SE-0306 + SE-0316: a member inherits its containing type's resolved isolation —
        // actor isolation only for instance members, global actor isolation for all members
        // (including static). Resolving the container recursively (rather than reading a raw
        // attribute) means a container that only reaches its isolation via the module default
        // or its own superclass still propagates correctly. Nested types do not participate in
        // this propagation at all (see the type-level doc comment above).
        if !declaration.isNestedType,
           let containingUSR = declaration.containingTypeUSR,
           let containingType = declarations[containingUSR] {
            let containingIsolation = resolveIsolation(for: containingType, visiting: visiting)
            if case .actor = containingIsolation, !declaration.isStaticMember {
                return containingIsolation
            }
            if case .globalActor = containingIsolation {
                return containingIsolation
            }
        }

        // SE-0316: a class mandatorily inherits its superclass's global actor isolation.
        // Applies to nested types too -- this is about the declaration's own class hierarchy,
        // unrelated to nesting.
        if let superclassUSR = declaration.superclassUSR, let superclass = declarations[superclassUSR] {
            let superclassIsolation = resolveIsolation(for: superclass, visiting: visiting)
            if case .globalActor = superclassIsolation {
                return superclassIsolation
            }
        }

        // SE-0316: a type conforming to a global-actor-qualified protocol in the same file
        // as its primary definition infers that actor's isolation for the whole type.
        for conformance in declaration.conformances
        where conformance.declaredInSameFileAsPrimaryDefinition {
            if let actorName = conformance.protocolGlobalActorName {
                return .globalActor(name: actorName)
            }
        }

        // SE-0316: a witness satisfying a global-actor-isolated protocol requirement infers
        // that isolation when the conformance is stated in the same type/extension as the
        // witness, even if whole-type inference above didn't apply.
        for conformance in declaration.conformances
        where conformance.declaredInSameContextAsWitness {
            if let actorName = conformance.protocolGlobalActorName {
                return .globalActor(name: actorName)
            }
        }

        return nil
    }

    private func resolveDefaultIsolation(for declaration: DeclarationInfo, visiting: Set<String>) -> IsolationKind {
        guard declaration.isEligibleForModuleDefaultIsolation else { return .nonisolated }

        if declaration.isNestedType {
            // SE-0466: "declarations that are types nested within a nonisolated type" are
            // excluded from the default -- eligibility depends on the *enclosing type's own
            // resolved isolation*, not a flat per-declaration fact. Confirmed empirically both
            // directions: a nested type inside a default-eligible enclosing type picks up the
            // module default, the same nested type inside an explicitly nonisolated enclosing
            // type stays nonisolated even with the default configured.
            guard let containingUSR = declaration.containingTypeUSR,
                  let containingType = declarations[containingUSR],
                  resolveIsolation(for: containingType, visiting: visiting) != .nonisolated else {
                return .nonisolated
            }
        }

        return ruleSet.resolveDefaultIsolation(for: declaration)
    }
}
