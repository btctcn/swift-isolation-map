import ExternalDepCore

/// `DivergentIsolation` shape: proves USR selection picks the specific invoked member (the
/// `nonisolated init()`), not the type's own `@MainActor` -- the init-call edge must not be a
/// finding, while the `isolatedMethod()` call must be.
nonisolated func callDivergentInit() -> DivergentIsolation {
    // No `await` needed here -- `init()` is explicitly `nonisolated`, real ground truth confirmed
    // by `xcrun swiftc -typecheck` below. This is the edge that must *not* be a finding.
    DivergentIsolation()
}

nonisolated func callDivergentMethod(_ value: DivergentIsolation) async {
    await value.isolatedMethod()
}
