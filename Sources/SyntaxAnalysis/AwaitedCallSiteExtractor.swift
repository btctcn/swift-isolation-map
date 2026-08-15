import SwiftSyntax
import SwiftIfConfig

/// One `await <expr>` expression's own source range (issue #46,
/// `docs/task-await-aware-risk-classification.md`). Unlike `ClosureLiteralRecord`/
/// `ClassifiedClosure`, this needs no project-wide accept-list to interpret -- an `await` keyword
/// is unconditional, unambiguous evidence on its own, so extraction produces the final fact
/// directly, with no separate classification step.
///
/// A call-graph edge's own location (`IndexStoreDB`'s `.call`-role occurrence, at the referenced
/// symbol's own token) always falls inside the source range of any `await` expression wrapping
/// it, the same way a call site inside a closure literal always falls inside that closure's own
/// `{`/`}` range -- so containment, not an exact token match, is what `AnalysisReportBuilder`
/// tests an edge's location against.
public struct AwaitedRange: Equatable, Sendable {
    public let file: String
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int

    public init(file: String, startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.file = file
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }

    public func contains(line: Int, column: Int) -> Bool {
        let afterOrAtStart = line > startLine || (line == startLine && column >= startColumn)
        let beforeOrAtEnd = line < endLine || (line == endLine && column <= endColumn)
        return afterOrAtStart && beforeOrAtEnd
    }
}

public enum AwaitedCallSiteExtractor {
    public static func extract(
        from tree: SourceFileSyntax, fileName: String, converter: SourceLocationConverter,
        configuration: PlatformBuildConfiguration = PlatformBuildConfiguration(platform: .unknown)
    ) -> [AwaitedRange] {
        let visitor = Visitor(fileName: fileName, converter: converter, configuration: configuration)
        visitor.walk(tree)
        return visitor.ranges
    }

    private final class Visitor: PlatformAwareSyntaxVisitor {
        let fileName: String
        let converter: SourceLocationConverter
        var ranges: [AwaitedRange] = []

        init(fileName: String, converter: SourceLocationConverter, configuration: PlatformBuildConfiguration) {
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate, configuration: configuration)
        }

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            let end = converter.location(for: node.endPositionBeforeTrailingTrivia)
            ranges.append(AwaitedRange(file: fileName, startLine: start.line, startColumn: start.column, endLine: end.line, endColumn: end.column))
            return .visitChildren
        }
    }
}
