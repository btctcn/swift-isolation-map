import OutputFormat

/// Emits a mermaid `flowchart` diagram from an `AnalysisReport`. Node IDs are synthesized
/// (`n0`, `n1`, ...) rather than derived from the real USR -- real USRs (`s:...`) and this
/// project's own syntactic placeholder USRs routinely contain characters mermaid's flowchart
/// node-ID grammar doesn't accept (`:`, `(`, `)`, `.`, `#`), so a lookup table is simpler and
/// more robust than an escaping scheme.
enum MermaidWriter {
    static func write(_ report: AnalysisReport) -> String {
        let sortedNodes = report.nodes.sorted { $0.usr < $1.usr }
        var idByUSR: [String: String] = [:]
        for (index, node) in sortedNodes.enumerated() {
            idByUSR[node.usr] = "n\(index)"
        }

        var lines = ["flowchart LR"]
        for node in sortedNodes {
            let id = idByUSR[node.usr]!
            lines.append("    \(id)[\"\(escapeLabel(node.name))<br/>\(escapeLabel(node.isolation))\"]")
        }

        // Mermaid flowcharts have no per-edge `classDef`/`class` styling mechanism (`class`
        // statements only target nodes) -- edges are colored via `linkStyle <index> ...`,
        // addressed by the link's position among all `-->` statements in declaration order.
        // That's why edges are emitted first (establishing their index), then every
        // `linkStyle` line afterward, in the same order.
        var linkStyleLines: [String] = []
        var linkIndex = 0
        for edge in report.edges {
            guard let callerID = idByUSR[edge.callerUSR], let calleeID = idByUSR[edge.calleeUSR] else { continue }
            lines.append("    \(callerID) --> \(calleeID)")
            linkStyleLines.append("    linkStyle \(linkIndex) stroke:\(strokeColor(for: edge.risk)),stroke-width:2px")
            linkIndex += 1
        }
        lines.append(contentsOf: linkStyleLines)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func strokeColor(for risk: RiskLevel) -> String {
        switch risk {
        case .high: return "#e53935"
        case .medium: return "#fb8c00"
        case .low: return "#43a047"
        }
    }

    private static func escapeLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }
}
