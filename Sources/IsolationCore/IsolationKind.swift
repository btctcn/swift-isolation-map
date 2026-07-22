public enum IsolationKind: Equatable, Sendable {
    case actor(name: String)
    case globalActor(name: String)
    case nonisolated
    case unspecified
}
