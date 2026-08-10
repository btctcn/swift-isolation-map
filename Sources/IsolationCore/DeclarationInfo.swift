/// Isolation-relevant facts about one declaration (a type or a member), gathered from
/// SwiftSyntax attributes + IndexStoreDB structural relations (parent/child, conformances).
/// In v0.1 this is populated from fixtures; wiring real SwiftSyntax/IndexStoreDB data into
/// this shape is Priority 2 work (see docs/motivation.md and the architecture spec section 1.5).
public struct DeclarationInfo: Equatable, Sendable {
    public let usr: String
    public let name: String
    public let explicitIsolation: IsolationKind?
    public let isActorType: Bool
    public let containingTypeUSR: String?
    public let isStaticMember: Bool
    public let superclassUSR: String?
    public let conformances: [ProtocolConformance]
    public let isEligibleForModuleDefaultIsolation: Bool
    /// SE-0316's second, independent propagation rule: a global actor attribute on the
    /// *extension* a member is physically declared in, distinct from whatever the primary
    /// type declaration propagates. Wins over containing-type propagation, but an explicit
    /// attribute on the member itself still wins over this. See docs/isolation-rules.md, Gap C1.
    public let enclosingExtensionIsolation: IsolationKind?
    /// A type declared inside another type. Nested types do NOT inherit isolation via SE-0316's
    /// type->members propagation the way instance/static members do -- confirmed empirically,
    /// see docs/isolation-rules.md, Gap C2. They only ever reach isolation via an explicit
    /// attribute, their own superclass/conformances, or the module default -- and eligibility
    /// for that default is gated by whether their enclosing type itself resolves to nonisolated.
    public let isNestedType: Bool
    /// Where this declaration's name token sits in real source -- `nil` for fixture-only
    /// `DeclarationInfo` values that were never extracted from a real file (every existing
    /// fixture-based test predates this field, hence optional/defaulted, not a breaking change).
    /// Populated by `SyntaxAnalysis.DeclarationExtractor`; consumed by
    /// `IndexStoreIntegration`'s USR-linking layer to match this syntactic placeholder against
    /// IndexStoreDB's real symbol occurrences for the same file. Confirmed empirically that
    /// SwiftSyntax's `SourceLocation` (1-based line, 1-based UTF-8-byte column, measured at the
    /// name token) and IndexStoreDB's `SymbolLocation` (`line`/`utf8Column`) use the *same*
    /// convention and point at the *same* position for the same real symbol -- see
    /// docs/priority-2-phase-3-linking.md.
    public let location: SymbolLocation?
    /// A `let`-bound stored property -- always immutable, single-assignment, and (unlike a `var`)
    /// never computed in Swift (a `let` cannot carry a getter/accessor block). Reading an
    /// immutable stored property from a *different* isolation domain than the one it's isolated to
    /// is real, compiler-permitted, race-free Swift -- confirmed empirically (`nonisolated`
    /// synchronous code reading a `let` stored property of an unrelated `@MainActor` struct
    /// compiles with zero diagnostics, no `await` needed) -- so a cross-isolation edge whose
    /// *callee* is one is never a real risk, regardless of which two isolation domains are
    /// involved. Consumed by `AnalysisReportBuilder`'s risk suppression, mirroring its existing
    /// "isolated caller reaching a confirmed `.nonisolated` callee" carve-out.
    public let isImmutableStoredProperty: Bool

    public init(
        usr: String,
        name: String,
        explicitIsolation: IsolationKind? = nil,
        isActorType: Bool = false,
        containingTypeUSR: String? = nil,
        isStaticMember: Bool = false,
        superclassUSR: String? = nil,
        conformances: [ProtocolConformance] = [],
        isEligibleForModuleDefaultIsolation: Bool = true,
        enclosingExtensionIsolation: IsolationKind? = nil,
        isNestedType: Bool = false,
        location: SymbolLocation? = nil,
        isImmutableStoredProperty: Bool = false
    ) {
        self.usr = usr
        self.name = name
        self.explicitIsolation = explicitIsolation
        self.isActorType = isActorType
        self.containingTypeUSR = containingTypeUSR
        self.isStaticMember = isStaticMember
        self.superclassUSR = superclassUSR
        self.conformances = conformances
        self.isEligibleForModuleDefaultIsolation = isEligibleForModuleDefaultIsolation
        self.enclosingExtensionIsolation = enclosingExtensionIsolation
        self.isNestedType = isNestedType
        self.location = location
        self.isImmutableStoredProperty = isImmutableStoredProperty
    }
}

/// Models both directions SE-0316 grants conformance-based inference:
/// whole-type inference (conformance declared in the same file as the type's primary
/// definition) and per-witness inference (conformance declared in the same type/extension
/// as the witnessing member).
public struct ProtocolConformance: Equatable, Sendable {
    public let protocolUSR: String
    public let protocolGlobalActorName: String?
    public let declaredInSameFileAsPrimaryDefinition: Bool
    public let declaredInSameContextAsWitness: Bool

    public init(
        protocolUSR: String,
        protocolGlobalActorName: String?,
        declaredInSameFileAsPrimaryDefinition: Bool,
        declaredInSameContextAsWitness: Bool
    ) {
        self.protocolUSR = protocolUSR
        self.protocolGlobalActorName = protocolGlobalActorName
        self.declaredInSameFileAsPrimaryDefinition = declaredInSameFileAsPrimaryDefinition
        self.declaredInSameContextAsWitness = declaredInSameContextAsWitness
    }
}
