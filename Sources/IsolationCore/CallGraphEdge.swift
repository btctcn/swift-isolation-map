public struct CallGraphEdge: Equatable, Sendable {
    public let callerUSR: String
    public let calleeUSR: String
    public let location: SymbolLocation

    public init(callerUSR: String, calleeUSR: String, location: SymbolLocation) {
        self.callerUSR = callerUSR
        self.calleeUSR = calleeUSR
        self.location = location
    }
}
