import Testing
@testable import IsolationCore

@Test func isolationKindEquality() {
    #expect(IsolationKind.actor(name: "UserSession") == IsolationKind.actor(name: "UserSession"))
    #expect(IsolationKind.actor(name: "UserSession") != IsolationKind.nonisolated)
}
