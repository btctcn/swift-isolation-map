/// The syntactic declaration kinds this module distinguishes, restricted to what
/// `isEligibleForModuleDefaultIsolation` actually needs to decide. Not exposed outside this
/// module -- `IsolationCore.DeclarationInfo` has no notion of "kind," only the derived Bool.
enum SyntacticDeclarationKind {
    case actorType
    case classType
    case structType
    case enumType
    case typealiasDecl
    case enumCase
    case function
    case initializerDecl
    case variableProperty
    case subscriptDecl
    case accessor
}

/// SE-0466's exclusion list (quoted in full in `docs/isolation-rules.md`, rule 12): "enum cases,
/// typealiases, accessors, actor-type members, `SendableMetatype`-conforming types, nested types
/// in nonisolated types" are excluded from picking up a configured module default.
///
/// Nested-types-in-nonisolated-types is deliberately **not** encoded here -- that exclusion
/// depends on the *enclosing type's own resolved isolation*, which isn't a static fact knowable
/// per-declaration (see `docs/isolation-rules.md`, Gap C2); `IsolationInferenceEngine`'s
/// `resolveDefaultIsolation` already implements that half of rule 12 dynamically. This function
/// only covers the facts that genuinely are local to one declaration.
///
/// `directlyConformsToSendableMetatype` only recognizes a literal `SendableMetatype`/`Sendable`
/// conformance written on the declaration itself -- a protocol that itself refines
/// `SendableMetatype` without saying so by name (transitive conformance) can't be detected from
/// syntax alone and is a documented Phase 1 limitation, not a silent gap.
func isEligibleForModuleDefaultIsolation(
    kind: SyntacticDeclarationKind,
    isMemberOfActorType: Bool,
    directlyConformsToSendableMetatype: Bool
) -> Bool {
    switch kind {
    case .typealiasDecl, .enumCase, .accessor:
        return false
    case .actorType, .classType, .structType, .enumType, .function, .initializerDecl,
         .variableProperty, .subscriptDecl:
        break
    }
    if isMemberOfActorType { return false }
    if directlyConformsToSendableMetatype { return false }
    return true
}
