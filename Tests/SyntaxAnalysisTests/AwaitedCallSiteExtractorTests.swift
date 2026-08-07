import Testing
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis

private func extract(_ source: String, file: String = "Test.swift") -> [AwaitedRange] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: file, tree: tree)
    return AwaitedCallSiteExtractor.extract(from: tree, fileName: file, converter: converter)
}

@Suite("AwaitedCallSiteExtractor: raw evidence extraction (issue #46)")
struct AwaitedCallSiteExtractorTests {
    @Test("A plain synchronous call with no await produces no ranges at all")
    func noAwaitProducesNoRanges() {
        let ranges = extract("""
        func trigger() {
            doSomething()
        }
        """)
        #expect(ranges.isEmpty)
    }

    @Test("An awaited call produces exactly one range covering the await expression")
    func awaitedCallProducesOneRange() {
        let ranges = extract("""
        func trigger() async {
            await doSomething()
        }
        """)
        #expect(ranges.count == 1)
    }

    @Test("The recorded range contains the call site's own location, the same way a call graph edge's location is measured")
    func rangeContainsTheCallSiteLocation() {
        let source = """
        func trigger() async {
            await doSomething()
        }
        """
        let ranges = extract(source)
        let range = try! #require(ranges.first)
        // "doSomething" starts at line 2, column 11 (1-based line, 1-based UTF-8 column: "    await " is 10 characters).
        #expect(range.contains(line: 2, column: 11))
        // Anything before the `await` keyword itself, or on an unrelated line, is not contained.
        #expect(!range.contains(line: 1, column: 1))
        #expect(!range.contains(line: 3, column: 1))
    }

    @Test("A file's ranges each carry that file's own name")
    func rangesCarryTheFileName() {
        let ranges = extract("""
        func trigger() async {
            await doSomething()
        }
        """, file: "Widget.swift")
        #expect(ranges.first?.file == "Widget.swift")
    }

    @Test("Multiple independent awaits in the same function each produce their own range")
    func multipleAwaitsProduceMultipleRanges() {
        let ranges = extract("""
        func trigger() async {
            await first()
            await second()
        }
        """)
        #expect(ranges.count == 2)
    }

    @Test("A call nested inside an unrelated await expression (e.g. an argument) is still contained by that outer range")
    func nestedCallInsideAwaitedArgumentIsContained() {
        // `await` applies to the whole compound expression `process(value: helper())` here --
        // `helper()` (a plain synchronous call, no await of its own) is still lexically inside the
        // awaited range. This is a deliberate, documented over-approximation (range containment,
        // not an exact awaited-token match) -- see AwaitedCallSiteExtractor.swift's own doc comment.
        let source = """
        func trigger() async {
            await process(value: helper())
        }
        """
        let ranges = extract(source)
        let range = try! #require(ranges.first)
        // "helper" starts at line 2, column 26.
        #expect(range.contains(line: 2, column: 26))
    }
}
