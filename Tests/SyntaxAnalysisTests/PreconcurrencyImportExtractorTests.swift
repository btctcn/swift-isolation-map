import Testing
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis

private func extract(_ source: String, file: String = "Test.swift") -> [PreconcurrencyImportedModule] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: file, tree: tree)
    return PreconcurrencyImportExtractor.extract(from: tree, fileName: file, converter: converter)
}

@Suite("PreconcurrencyImportExtractor (docs/task-escape-hatch-and-preconcurrency-severity.md, PR2, shape 4)")
struct PreconcurrencyImportExtractorTests {
    @Test("A plain import (no @preconcurrency) produces no findings")
    func plainImportProducesNothing() {
        let modules = extract("import Foundation")
        #expect(modules.isEmpty)
    }

    @Test("A single @preconcurrency import produces one finding with the plain module name")
    func preconcurrencyImportProducesOneFinding() {
        let modules = extract("@preconcurrency import WebKit")
        #expect(modules.count == 1)
        #expect(modules.first?.moduleName == "WebKit")
    }

    @Test("A Clang-submodule import keeps only the first, top-level path component -- the same normalization rule the callee side (sourcekitd's own key.modulename) uses")
    func submoduleImportKeepsOnlyTopLevelComponent() {
        let modules = extract("@preconcurrency import Foundation.NSDebug")
        #expect(modules.count == 1)
        #expect(modules.first?.moduleName == "Foundation")
    }

    @Test("A finding carries its own file name and the import statement's own line")
    func findingCarriesFileAndLine() {
        let modules = extract("""
        import Foundation

        @preconcurrency import WebKit
        """, file: "Widget.swift")
        let module = try! #require(modules.first)
        #expect(module.file == "Widget.swift")
        #expect(module.moduleName == "WebKit")
        #expect(module.line == 3)
    }

    @Test("Multiple @preconcurrency imports in the same file each produce their own finding")
    func multiplePreconcurrencyImportsProduceMultipleFindings() {
        let modules = extract("""
        @preconcurrency import WebKit
        @preconcurrency import LocalAuthentication
        import Foundation
        """)
        #expect(Set(modules.map(\.moduleName)) == ["WebKit", "LocalAuthentication"])
    }
}
