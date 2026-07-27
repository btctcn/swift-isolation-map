import ExternalDepDefault

/// Module-default shape: `ModuleDefaultIsolated` has no attribute anywhere and no isolated
/// ancestor -- isolation comes solely from `ExternalDepDefault`'s own `-default-isolation
/// MainActor` build flag. Proves the oracle resolves this at the member-query granularity even
/// though the bare type declaration itself carries no visible attribute
/// (`docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`'s "Second addendum").
nonisolated func callModuleDefault() async {
    let value = await ModuleDefaultIsolated()
    await value.touch()
}
