public final class IsolationInferenceEngine {
    public let attributes: [String: IsolationAttribute]
    public let callGraph: [CallGraphEdge]
    public let ruleSet: IsolationRuleSet

    public init(attributes: [String: IsolationAttribute], callGraph: [CallGraphEdge], ruleSet: IsolationRuleSet) {
        self.attributes = attributes
        self.callGraph = callGraph
        self.ruleSet = ruleSet
    }

    /// Resolution priority:
    /// 1. Explicit attribute on the declaration
    /// 2. Inheritance from the containing type
    /// 3. Default actor isolation (depends on Swift version / rule set)
    /// 4. Protocol conformance isolation
    public func resolveIsolation(for usr: String) -> IsolationKind {
        fatalError("not implemented")
    }

    public func crossIsolationEdges() -> [CallGraphEdge] {
        callGraph.filter { edge in
            resolveIsolation(for: edge.callerUSR) != resolveIsolation(for: edge.calleeUSR)
        }
    }
}
