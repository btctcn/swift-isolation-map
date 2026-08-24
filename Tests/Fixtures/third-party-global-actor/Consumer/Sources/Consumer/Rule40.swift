import ThirdPartyActorKit

/// Rule A's exact shape from `docs/task-closure-isolation-attribution.md`, just with a
/// third-party global actor instead of `@MainActor`: an isolation-establishing closure attribute
/// (`{ @ThirdPartyActor in ... }`) whose enclosing declaration (`callFromNonisolated`) is plain
/// `nonisolated`. Ground truth (see the paired `swiftc -typecheck` check): this call is genuinely
/// safe -- the closure really does run on `ThirdPartyActor`.
func callFromNonisolated() {
    Task { @ThirdPartyActor in
        thirdPartyIsolatedWork()
    }
}

/// Control, no closure involved at all -- a genuine cross-isolation call (nonisolated caller,
/// await-ing into ThirdPartyActor-isolated state), matching this tool's own precedent for how
/// every other already-awaited nonisolated->isolated crossing is reported (CompiledDependencyCLITests'
/// Mechanism A): a real migration-debt edge, correctly flagged .high, not a false positive.
func plainDirectCall() async {
    await thirdPartyIsolatedWork()
}
