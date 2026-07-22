public struct SwiftVersionRange: Equatable, Sendable {
    public let lowerBound: String
    public let upperBound: String?

    public init(lowerBound: String, upperBound: String?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct TypeContext: Equatable, Sendable {
    public let usr: String
    public let isProtocolConformance: Bool

    public init(usr: String, isProtocolConformance: Bool) {
        self.usr = usr
        self.isProtocolConformance = isProtocolConformance
    }
}

public protocol IsolationRuleSet: Sendable {
    var swiftVersion: SwiftVersionRange { get }
    func resolveDefaultIsolation(for context: TypeContext) -> IsolationKind
}

/// No default MainActor isolation.
public struct Swift5RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "5.0", upperBound: "5.10")

    public init() {}

    public func resolveDefaultIsolation(for context: TypeContext) -> IsolationKind {
        fatalError("not implemented")
    }
}

/// Opt-in strict concurrency checking.
public struct Swift6RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.0", upperBound: "6.1")

    public init() {}

    public func resolveDefaultIsolation(for context: TypeContext) -> IsolationKind {
        fatalError("not implemented")
    }
}

/// Default MainActor isolation.
public struct Swift62RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.2", upperBound: nil)

    public init() {}

    public func resolveDefaultIsolation(for context: TypeContext) -> IsolationKind {
        fatalError("not implemented")
    }
}
