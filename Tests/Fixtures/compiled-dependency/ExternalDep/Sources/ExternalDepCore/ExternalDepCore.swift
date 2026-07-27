import Foundation

/// Case 4 shape ("inferred-isolation trap"): a leaf subclass with **no** attribute of its own,
/// isolation only reachable by resolving `IsolatedRoot`'s own isolation first -- the exact case
/// `docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`'s research thread proved
/// `sourcekitd` resolves correctly, empirically, more than once.
@MainActor
open class IsolatedRoot {
    public init() {}
    open func touch() {}
}

open class InferredChild: IsolatedRoot {}

/// The member/type isolation divergence shape: an otherwise-`@MainActor` type with an explicitly
/// `nonisolated` initializer -- proves USR-based result selection picks the specific invoked
/// member, not the type as a whole (`docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`'s
/// "Second addendum").
@MainActor
open class DivergentIsolation {
    nonisolated public init() {}
    open func isolatedMethod() {}
}

/// Negative control: a genuinely, unambiguously nonisolated external type -- no attribute
/// anywhere in its chain, nothing to infer. Must never be misreported as isolated.
open class PlainNonisolated {
    public init() {}
    open func touch() {}
}
