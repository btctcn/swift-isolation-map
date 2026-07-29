/// Shared positive-validation logic for `SymbolGraphIsolationParser` and `FullyAnnotatedDeclParser`:
/// an attribute fragment/XML element resolving to a real type via USR is not, by itself, evidence
/// that type is a global actor. Confirmed real, non-hypothetical on `Project Iris`
/// (docs/task-oracle-query-concurrency.md's decision record, `KFImageRenderer`): a property
/// declared `@StateObject private var binder: ImageBinder` queried directly resolved its own
/// isolation as `globalActor(name: "StateObject")` -- `StateObject` is a SwiftUI property wrapper,
/// never a global actor, and hovering that declaration's own line legitimately reflects the
/// type-wide `@MainActor` isolation `KFImageRenderer` gets from conforming to `View`, but neither
/// parser distinguished the wrapper attribute from the isolation attribute; both simply matched
/// "the first/any attribute fragment with a resolvable USR."
enum GlobalActorNameValidation {
    /// `MainActor`'s own USR is fixed and always valid -- the overwhelming common case, and a fast
    /// path that needs no name-based judgment at all.
    private static let mainActorUSR = "s:ScM"

    /// Real SwiftUI/Combine/Observation property wrappers with no actor-isolation meaning of their
    /// own -- excluded by name, a documented, temporary measure (not a live `@globalActor`-attribute
    /// check against the referenced type's own declaration, which would need a second live query
    /// per candidate). A real custom global actor happening to share one of these names would be a
    /// false negative (`.nonisolated`, an undercount) -- not the fabricated-isolation failure mode
    /// this validation exists to close, and no such collision is known in this project's real
    /// corpus. See docs/task-oracle-query-concurrency.md's decision record.
    private static let knownNonActorAttributeNames: Set<String> = [
        "State", "StateObject", "Published", "ObservedObject", "Binding", "EnvironmentObject",
        "Environment", "AppStorage", "SceneStorage", "FocusState", "GestureState", "Namespace",
        "ScaledMetric", "Bindable", "Observable",
    ]

    static func isGlobalActorName(spelling: String, usr: String?) -> Bool {
        if usr == mainActorUSR { return true }
        return !knownNonActorAttributeNames.contains(spelling)
    }
}
