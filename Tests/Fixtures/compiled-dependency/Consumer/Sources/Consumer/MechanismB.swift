import SwiftUI

/// Mechanism B: a real, pure-Swift, library-evolution-enabled `@MainActor` protocol
/// (`SwiftUI.View`, `.swiftinterface`-backed) -- same real-SDK-type approach as mechanism A, no
/// synthetic dependency needed.
struct ProjectView: View {
    var body: some View {
        Text("hi")
    }
}

// A plain struct's synthesized memberwise initializer does not itself inherit the `View`
// protocol's `@MainActor` isolation (confirmed empirically: the `await` below was flagged
// "no async operations occur" -- real, not assumed) -- so this fixture verifies mechanism B's
// resolution via `ProjectView`'s own reported node isolation (asserted in
// `CompiledDependencyCLITests.swift`), not via a constructed cross-isolation call edge the way
// the other mechanisms are.
nonisolated func callMechanismB() -> ProjectView {
    ProjectView()
}
