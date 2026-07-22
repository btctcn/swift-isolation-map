public struct IsolationAttribute: Equatable, Sendable {
    public let usr: String
    public let kind: IsolationKind
    public let location: SymbolLocation

    public init(usr: String, kind: IsolationKind, location: SymbolLocation) {
        self.usr = usr
        self.kind = kind
        self.location = location
    }
}
