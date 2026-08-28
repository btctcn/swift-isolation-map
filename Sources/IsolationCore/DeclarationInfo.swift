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
    /// An actor's *own* initializer -- structurally distinct from its instance methods,
    /// properties, and subscripts. SE-0306's own text (quoted in `docs/isolation-rules.md`'s rule
    /// 3) says only "the instance methods, properties, and subscripts of an actor have an
    /// isolated `self` parameter" -- initializers are conspicuously absent, and real Swift
    /// confirms it: `actor A { init() {} }; nonisolated func f() { A() }` compiles with zero
    /// diagnostics under `-strict-concurrency=complete`, no `await` needed, since constructing a
    /// new actor instance doesn't require prior access to that (not-yet-existing) instance.
    /// Confirmed a real, reproduced gap on `WordPress-iOS`: calling an actor's own initializer
    /// from `nonisolated` code (`StatsService(...)`, `WordPressClient(...)`, ...) was reported as
    /// a `high`-risk `nonisolated -> actor(...)` boundary. Consumed by `AnalysisReportBuilder`'s
    /// risk suppression, mirroring `isImmutableStoredProperty`'s own carve-out immediately above --
    /// `IsolationInferenceEngine` itself stays untouched; the init's own resolved isolation is
    /// still (correctly, structurally) `.actor(name)` for anything that legitimately needs it
    /// (e.g. a call from *within* the same actor), only the edge-level risk report changes.
    public let isActorInitializer: Bool
    /// `@preconcurrency` on *this* declaration/member itself. Confirmed by direct `swiftc
    /// -swift-version 6` test (docs/task-escape-hatch-and-preconcurrency-severity.md, Step 2) that
    /// this attribute on a type also softens the same diagnostic for that type's own unannotated
    /// members (including ones declared in an `extension`) -- so a consumer checking "is this
    /// callee's boundary softened by `@preconcurrency`" must check this flag on the declaration
    /// itself **or** on `containingTypeUSR`'s own `DeclarationInfo`, never this field alone.
    public let hasPreconcurrencyAttribute: Bool
    /// `nonisolated(unsafe)` on this member (only meaningful for a stored property -- the only
    /// declaration shape the attribute is valid on). Distinct from `explicitIsolation`, which
    /// already correctly resolves this to `.nonisolated` for isolation purposes and is unaffected
    /// by this field -- this only exists to surface the escape hatch itself as an
    /// `EscapeHatchFinding`, never to change isolation resolution.
    public let isNonisolatedUnsafe: Bool

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
        isImmutableStoredProperty: Bool = false,
        isActorInitializer: Bool = false,
        hasPreconcurrencyAttribute: Bool = false,
        isNonisolatedUnsafe: Bool = false
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
        self.isActorInitializer = isActorInitializer
        self.hasPreconcurrencyAttribute = hasPreconcurrencyAttribute
        self.isNonisolatedUnsafe = isNonisolatedUnsafe
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
    /// `@unchecked` on this conformance -- Swift's grammar only ever pairs this attribute with
    /// `Sendable` (SE-0302), so this being `true` always means an `@unchecked Sendable`
    /// conformance specifically, never a generic "unchecked" anything-else. Informational only --
    /// consumed as an `EscapeHatchFinding`, never affects isolation resolution or edge risk.
    public let isUnchecked: Bool
    /// `@preconcurrency` on this conformance clause entry. **Deliberately never consulted by the
    /// edge-severity-downgrade mechanism** -- confirmed against SE-0423's own text that this
    /// softens only a one-time witness-checker diagnostic at the conformance declaration itself,
    /// not diagnostics for arbitrary calls to the conforming type's methods (see
    /// docs/task-escape-hatch-and-preconcurrency-severity.md's own correction, made after an
    /// earlier draft of that mechanism got this wrong). Informational only, surfaced as an
    /// `EscapeHatchFinding`.
    public let isPreconcurrency: Bool

    public init(
        protocolUSR: String,
        protocolGlobalActorName: String?,
        declaredInSameFileAsPrimaryDefinition: Bool,
        declaredInSameContextAsWitness: Bool,
        isUnchecked: Bool = false,
        isPreconcurrency: Bool = false
    ) {
        self.protocolUSR = protocolUSR
        self.protocolGlobalActorName = protocolGlobalActorName
        self.declaredInSameFileAsPrimaryDefinition = declaredInSameFileAsPrimaryDefinition
        self.declaredInSameContextAsWitness = declaredInSameContextAsWitness
        self.isUnchecked = isUnchecked
        self.isPreconcurrency = isPreconcurrency
    }
}
