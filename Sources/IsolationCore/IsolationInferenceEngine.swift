/// Resolves the actor isolation of every declaration in a project by combining explicit
/// attributes with structural inheritance and module-level defaults.
///
/// Resolution order (see docs/isolation-rules.md for the SE-proposal citation behind each step):
/// 1. Explicit isolation attribute on the declaration itself.
/// 2. Isolation inherited from a containing actor type, a global-actor-attributed containing
///    type, a global-actor-isolated superclass, or a same-context protocol conformance —
///    the containing/superclass isolation is resolved recursively through this same
///    priority order, so a type that only reaches @MainActor via the module default still
///    propagates it to its members and subclasses.
/// 3. The rule set's module-level default isolation (SE-0466), only for declarations both
///    untouched by 1-2 and eligible for defaulting.
/// 4. `.nonisolated` as the final fallback.
///
/// Note this reorders the architecture spec's original "default before protocol conformance"
/// sketch: SE-0466 explicitly excludes from default-isolation any declaration with "inferred
/// actor isolation from a superclass, overridden method, protocol conformance, or member
/// propagation" — inheritance must be resolved before the default is even considered.
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
        if let inherited = resolveInheritedIsolation(for: declaration, visiting: visiting) {
            return inherited
        }
        if declaration.isEligibleForModuleDefaultIsolation {
            return ruleSet.resolveDefaultIsolation(for: declaration)
        }
        return .nonisolated
    }

    private func resolveInheritedIsolation(for declaration: DeclarationInfo, visiting: Set<String>) -> IsolationKind? {
        // SE-0306 + SE-0316: a member inherits its containing type's resolved isolation —
        // actor isolation only for instance members, global actor isolation for all members
        // (including static). Resolving the container recursively (rather than reading a raw
        // attribute) means a container that only reaches its isolation via the module default
        // or its own superclass still propagates correctly.
        if let containingUSR = declaration.containingTypeUSR, let containingType = declarations[containingUSR] {
            let containingIsolation = resolveIsolation(for: containingType, visiting: visiting)
            if case .actor = containingIsolation, !declaration.isStaticMember {
                return containingIsolation
            }
            if case .globalActor = containingIsolation {
                return containingIsolation
            }
        }

        // SE-0316: a class mandatorily inherits its superclass's global actor isolation.
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
}
