import ExternalDepCore

/// Case 4: a project-local subclass of a `.swiftmodule`-only (no `.swiftinterface` at all)
/// dependency's type, which itself has no attribute of its own -- isolation only reachable by
/// resolving `IsolatedRoot`'s isolation, then `InferredChild`'s, then this subclass's, in a chain
/// with zero attributes physically written anywhere.
final class ProjectSubclassOfInferredChild: InferredChild {}

nonisolated func callCase4() async {
    let value = await ProjectSubclassOfInferredChild()
    await value.touch()
}
