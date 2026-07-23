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

    public init(
        usr: String,
        name: String,
        explicitIsolation: IsolationKind? = nil,
        isActorType: Bool = false,
        containingTypeUSR: String? = nil,
        isStaticMember: Bool = false,
        superclassUSR: String? = nil,
        conformances: [ProtocolConformance] = [],
        isEligibleForModuleDefaultIsolation: Bool = true
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
