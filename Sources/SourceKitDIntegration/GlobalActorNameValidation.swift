/// Shared positive-validation logic for `SymbolGraphIsolationParser` and `FullyAnnotatedDeclParser`:
/// an attribute fragment/XML element resolving to a real type via USR is not, by itself, evidence
/// that type is a global actor. Confirmed real, non-hypothetical on two separate real projects:
/// `Project Iris` (docs/task-oracle-query-concurrency.md's decision record, `KFImageRenderer`): a
/// property declared `@StateObject private var binder: ImageBinder` queried directly resolved its
/// own isolation as `globalActor(name: "StateObject")`; and `Swiftfin`, which turned up *eleven*
/// more fabricated names in one real run alone -- third-party property wrappers (`@Default` from
/// the `Defaults` package, `@Injected`/`@InjectedObject` from `FactoryKit`), a project-local
/// `@Router` wrapper, `@resultBuilder`-annotated closures/params (`ArrayBuilder`,
/// `TabContentBuilder`, `ViewBuilder`), and -- decisively -- multiple project-local
/// `DynamicProperty`-conforming wrappers (`CurrentDate`, `StateOrBinding`, `ViewContextContains`)
/// plus at least one wrapper name (`Indirect`) that isn't declared anywhere in the project's own
/// source at all, only in one of its ~30 SPM dependencies. `StateObject` is a SwiftUI property
/// wrapper, never a global actor, and hovering that declaration's own line legitimately reflects
/// the type-wide `@MainActor` isolation `KFImageRenderer` gets from conforming to `View`, but
/// neither parser distinguished the wrapper attribute from the isolation attribute; both simply
/// matched "the first/any attribute fragment with a resolvable USR."
///
/// A **denylist of known-bad names** (this type's own previous shape) cannot close this: any
/// project can declare an arbitrarily-named custom property wrapper or result builder, and every
/// new project tried surfaces new names a fixed list never anticipated (confirmed twice now, by
/// two unrelated real projects each contributing names the other never used). The fix is an
/// **allowlist** instead: accept a name only if it's `MainActor` (the fixed, universal fast path)
/// or a name this project's *own* syntactic scan (`FileWideNameCollector`) confirmed is really
/// declared `@globalActor` somewhere in the analyzed source (`knownGlobalActorNames`, unioned
/// project-wide by `DeclarationLinker`). **Known, accepted limitation, the inverse of the old
/// denylist's own**: a genuinely real custom global actor declared *outside* the analyzed
/// project's own files (in a dependency, or an SDK module) is invisible to this check and would
/// undercount to `.nonisolated` -- a false negative (missing data), not the fabricated-isolation
/// false positive (wrong data) this validation exists to prevent. Given how common arbitrary
/// property wrappers/result builders are in real SwiftUI code, and how rare a *dependency-declared*
/// custom global actor is, this trade favors correctness over completeness.
enum GlobalActorNameValidation {
    /// `MainActor`'s own USR is fixed and always valid -- the overwhelming common case, and a fast
    /// path that needs no name-based judgment (or project context) at all.
    private static let mainActorUSR = "s:ScM"

    static func isGlobalActorName(spelling: String, usr: String?, knownGlobalActorNames: Set<String>) -> Bool {
        if usr == mainActorUSR { return true }
        return knownGlobalActorNames.contains(spelling)
    }
}
