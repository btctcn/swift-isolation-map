import SwiftSyntax
import SwiftIfConfig

/// One `@preconcurrency import Foo[.Bar...]`'s own top-level module name, together with the file
/// it was found in (docs/task-escape-hatch-and-preconcurrency-severity.md, PR2, shape 4) --
/// self-describing its own file the same way `AwaitedRange` does, so a multi-file caller
/// (`IndexStoreIntegration.DeclarationLinker`) can flatten and group by file without needing a
/// separate "which file was this `ExtractionResult` for" input.
public struct PreconcurrencyImportedModule: Equatable, Sendable {
    public let file: String
    public let line: Int
    public let moduleName: String

    public init(file: String, line: Int, moduleName: String) {
        self.file = file
        self.line = line
        self.moduleName = moduleName
    }
}

/// Every `@preconcurrency import Foo[.Bar...]` in one file, reduced to `Foo`'s own top-level
/// module name. Needs no project-wide classification step, like `AwaitedCallSiteExtractor` -- an
/// import attribute is unconditional, unambiguous evidence on its own.
///
/// Only the *first* `.`-separated path component is kept, even for a genuine Clang-submodule
/// import (`import Dispatch.Introspection`) -- confirmed the matching rule on the callee side
/// (`ExternalIsolationBackfill.topLevelModuleName(from:)`, `sourcekitd`'s own `key.modulename`)
/// uses the same first-component reduction for a real, dotted `"Module.Type"`/
/// `"Module.Submodule.Type"` shape, so both sides of the eventual downgrade-lookup comparison need
/// to agree on the identical normalization rule, not two different assumptions about where a
/// module name "really" ends.
public enum PreconcurrencyImportExtractor {
    public static func extract(
        from tree: SourceFileSyntax, fileName: String, converter: SourceLocationConverter,
        configuration: PlatformBuildConfiguration = PlatformBuildConfiguration(platform: .unknown)
    ) -> [PreconcurrencyImportedModule] {
        let visitor = Visitor(fileName: fileName, converter: converter, configuration: configuration)
        visitor.walk(tree)
        return visitor.modules
    }

    private final class Visitor: PlatformAwareSyntaxVisitor {
        let fileName: String
        let converter: SourceLocationConverter
        var modules: [PreconcurrencyImportedModule] = []

        init(fileName: String, converter: SourceLocationConverter, configuration: PlatformBuildConfiguration) {
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate, configuration: configuration)
        }

        override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.attributes.contains(named: "preconcurrency"), let topLevelName = node.path.first?.name.text else {
                return .skipChildren
            }
            let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            modules.append(PreconcurrencyImportedModule(file: fileName, line: line, moduleName: topLevelName))
            return .skipChildren
        }
    }
}
