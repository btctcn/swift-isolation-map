import OutputFormat

/// Emits a Graphviz DOT digraph from an `AnalysisReport`. Unlike mermaid, DOT node IDs can be
/// arbitrary quoted strings, so the real USR is used directly as the node ID -- no synthesized
/// lookup table needed.
enum DotWriter {
    static func write(_ report: AnalysisReport) -> String {
        var lines = ["digraph SwiftIsolationMap {", "    rankdir=LR;"]

        for node in report.nodes.sorted(by: { $0.usr < $1.usr }) {
            // DOT's own `\n` label line-break directive is inserted *after* escaping each raw
            // component individually -- running the assembled label through `quote()` as a
            // whole would double-escape that literal backslash into `\\n` (a visible two-
            // character "\n" in the rendered graph, not an actual line break).
            let label = "\(escape(node.name))\\n\(escape(node.isolation))"
            lines.append("    \(quote(node.usr)) [label=\"\(label)\"];")
        }

        for edge in report.edges {
            let attributes = "color=\(quote(strokeColor(for: edge.risk))), penwidth=\(penwidth(for: edge.risk)), label=\(quote(edge.risk.rawValue))"
            lines.append("    \(quote(edge.callerUSR)) -> \(quote(edge.calleeUSR)) [\(attributes)];")
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func strokeColor(for risk: RiskLevel) -> String {
        switch risk {
        case .high: return "#e53935"
        case .medium: return "#fb8c00"
        case .low: return "#43a047"
        }
    }

    private static func penwidth(for risk: RiskLevel) -> String {
        switch risk {
        case .high: return "2.5"
        case .medium: return "1.5"
        case .low: return "1.0"
        }
    }

    private static func quote(_ text: String) -> String {
        "\"\(escape(text))\""
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
