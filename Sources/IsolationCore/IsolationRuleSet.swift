public struct SwiftVersionRange: Equatable, Sendable {
    public let lowerBound: String
    public let upperBound: String?

    public init(lowerBound: String, upperBound: String?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Component-wise major.minor comparison — "5.10" is version 5.10, not 5.1.
    public func contains(_ version: String) -> Bool {
        guard let components = Self.components(of: version) else { return false }
        guard let lower = Self.components(of: lowerBound), !Self.isLess(components, than: lower) else { return false }
        guard let upperBound, let upper = Self.components(of: upperBound) else { return true }
        return !Self.isLess(upper, than: components)
    }

    private static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? nil : parts.map { $0! }
    }

    private static func isLess(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a != b { return a < b }
        }
        return lhs.count < rhs.count
    }
}

public protocol IsolationRuleSet: Sendable {
    var swiftVersion: SwiftVersionRange { get }

    /// Isolation for a declaration that has no explicit attribute and no isolation
    /// inherited from a containing type, superclass, or protocol conformance.
    /// Per SE-0466, inherited isolation always takes priority over the module default —
    /// callers must resolve inheritance first and only reach this for declarations where
    /// `isEligibleForModuleDefaultIsolation` is true.
    func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind
}

/// Swift 5 language mode: no `-default-isolation` mechanism exists (introduced in 6.2 by
/// SE-0466). Unattributed, uninherited declarations are nonisolated.
public struct Swift5RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "5.0", upperBound: "5.10")

    public init() {}

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        .nonisolated
    }
}

/// Swift 6 language mode (strict concurrency checking is mandatory), pre-6.2: same as
/// Swift 5 for default-isolation purposes — SE-0466 had not shipped yet.
public struct Swift6RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.0", upperBound: "6.1")

    public init() {}

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        .nonisolated
    }
}

/// Swift 6.2+: SE-0466 lets a module opt into `@MainActor`-by-default via the
/// `-default-isolation MainActor` compiler flag or `SwiftSetting.defaultIsolation(MainActor.self)`
/// in Package.swift. Per the proposal: "If no `-default-isolation` flag is specified, the
/// default isolation for the module is nonisolated" — MainActor is opt-in, never automatic
/// just from targeting Swift 6.2. `defaultIsolation` here must reflect the *actual* configured
/// value for the analyzed module/target, not be assumed.
public struct Swift62RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.2", upperBound: "6.3")
    public let defaultIsolation: IsolationKind

    public init(defaultIsolation: IsolationKind = .nonisolated) {
        self.defaultIsolation = defaultIsolation
    }

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        defaultIsolation
    }
}
