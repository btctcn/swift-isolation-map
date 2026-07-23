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

/// Pre-Swift-6 (5.0-5.10): kept as a single bucket, not one type per minor version.
/// This tool exists for the Swift 6 strict-concurrency migration; the 5.x range is
/// "not our primary audience," not a range actively reviewed release-by-release the way
/// 6.0-6.3 are below. See docs/isolation-rules.md, "Rule set version boundaries."
public struct Swift5RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "5.0", upperBound: "5.10")

    public init() {}

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        .nonisolated
    }
}

// MARK: - Swift 6.0-6.3, one type per version by design.
//
// Every Swift version actively in this tool's target range (mandatory strict concurrency
// onward) gets its own named rule set, even when its resolution logic is byte-identical to
// the previous version's. A version that changes nothing is still a deliberate, reviewed,
// git-blameable statement in the code ("I checked 6.x, nothing changed") rather than an
// implicit fact hidden in a range's upperBound — the latter is exactly what this project's
// "never silently assume" principle argues against. Concretely: adding support for a new
// Swift version always means adding a new type here, never editing an existing one's range.
// See docs/isolation-rules.md, "Rule set version boundaries," for the evolution-proposal
// evidence behind each of the "identical to" claims below.

/// Swift 6.0: strict concurrency checking became mandatory. No default-isolation mechanism
/// exists yet (SE-0466 ships in 6.2) — unattributed, uninherited declarations are nonisolated.
public struct Swift60RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.0", upperBound: "6.0")

    public init() {}

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        .nonisolated
    }
}

/// Swift 6.1: identical resolution behavior to 6.0. SE-0449 ("Allow `nonisolated` to prevent
/// global actor inference") only expands *where* `nonisolated` is legal to write syntactically
/// — it doesn't change what an already-resolved `nonisolated` attribute means, which is all
/// this engine consumes (`DeclarationInfo.explicitIsolation`, already past that question).
/// No other 6.1 proposal touches default-isolation. Written out explicitly rather than
/// delegating to `Swift60RuleSet`, even though the body is identical — one-line bodies don't
/// need indirection to stay obvious.
public struct Swift61RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.1", upperBound: "6.1")

    public init() {}

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        .nonisolated
    }
}

/// Swift 6.2: SE-0466 lets a module opt into `@MainActor`-by-default via the
/// `-default-isolation MainActor` compiler flag or `SwiftSetting.defaultIsolation(MainActor.self)`
/// in Package.swift. Per the proposal: "If no `-default-isolation` flag is specified, the
/// default isolation for the module is nonisolated" — MainActor is opt-in, never automatic
/// just from targeting Swift 6.2. `defaultIsolation` here must reflect the *actual* configured
/// value for the analyzed module/target, not be assumed.
public struct Swift62RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.2", upperBound: "6.2")
    public let defaultIsolation: IsolationKind

    public init(defaultIsolation: IsolationKind = .nonisolated) {
        self.defaultIsolation = defaultIsolation
    }

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        defaultIsolation
    }
}

/// Swift 6.3: identical resolution behavior to 6.2. SE-0481 (`weak let`) only relaxes a
/// Sendable-related mutability restriction on weak references; it doesn't touch
/// default-isolation inference. No other 6.3 proposal is isolation-relevant. Still takes the
/// same `-default-isolation` setting as 6.2, for the same reason (SE-0466's mechanism didn't
/// change either).
public struct Swift63RuleSet: IsolationRuleSet {
    public let swiftVersion = SwiftVersionRange(lowerBound: "6.3", upperBound: "6.3")
    public let defaultIsolation: IsolationKind

    public init(defaultIsolation: IsolationKind = .nonisolated) {
        self.defaultIsolation = defaultIsolation
    }

    public func resolveDefaultIsolation(for declaration: DeclarationInfo) -> IsolationKind {
        defaultIsolation
    }
}
