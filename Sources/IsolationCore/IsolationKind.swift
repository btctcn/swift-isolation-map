public enum IsolationKind: Equatable, Sendable, Codable {
    case actor(name: String)
    case globalActor(name: String)
    case nonisolated
    case unspecified
}
