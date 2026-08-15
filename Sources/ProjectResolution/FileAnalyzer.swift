import Foundation
import IsolationCore
import SyntaxAnalysis

public struct FileAnalysisResult: Equatable, Sendable {
    public let declarations: [DeclarationInfo]
    /// Threaded through from `ExtractionResult` (Priority 2 Phase 3) so a caller linking multiple
    /// files' results (`IndexStoreIntegration.DeclarationLinker`) has what it needs for cross-file
    /// `protocolGlobalActorName` backfill, without a second parse of the same source.
    public let protocolGlobalActorNames: [String: String]
    /// Threaded through the same way, for the same reason -- a protocol with no overall attribute
    /// but one or more individually `@GlobalActor`-attributed requirements (e.g. Swiftfin's own
    /// `PlatformView`). See `SyntaxAnalysis.TypeIndexBuilder.buildIndex`'s own doc comment.
    public let protocolRequirementGlobalActorNames: [String: [String: String]]
    /// Threaded through the same way -- see `SyntaxAnalysis.ExtractionResult`'s own field of the
    /// same name.
    public let protocolInheritedProtocolNames: [String: Set<String>]
    /// This file's own `@globalActor`-declared names, threaded through for the same reason --
    /// `DeclarationLinker` unions every file's set into one project-wide closure-attribute
    /// accept-list (`docs/task-closure-isolation-attribution.md` §7.3.1).
    public let globalActorNames: Set<String>
    /// This file's raw closure-literal evidence, threaded through for `DeclarationLinker` to
    /// classify once the project-wide accept-list above is assembled (same doc, §7.1).
    public let closureLiteralRecords: [ClosureLiteralRecord]
    /// This file's `await <expr>` ranges, threaded through for `AnalysisReportBuilder`'s
    /// await-aware risk classification (docs/task-await-aware-risk-classification.md, issue #46).
    public let awaitedRanges: [AwaitedRange]
    public let contentHash: String
}

public enum FileAnalysisError: Error, Equatable {
    case notUTF8(URL)
}

/// The one place Phase 1 (SwiftSyntax extraction) and Phase 2b (staleness hashing) aren't fully
/// independent of each other: architecture spec section 2.7's pipeline requires reading each
/// file's bytes exactly once and deriving *both* the parsed AST and the content hash from that
/// single read, not reading the file twice for two unrelated purposes.
public struct FileAnalyzer {
    let fileSystem: FileSystemQuerying

    public init(fileSystem: FileSystemQuerying = LiveFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func analyze(fileAt url: URL, platform: TargetPlatform = .unknown) throws -> FileAnalysisResult {
        let data = try fileSystem.readData(at: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw FileAnalysisError.notUTF8(url)
        }
        let extraction = DeclarationExtractor.extractWithContext(source: source, fileName: url.path, platform: platform)
        return FileAnalysisResult(
            declarations: extraction.declarations,
            protocolGlobalActorNames: extraction.protocolGlobalActorNames,
            protocolRequirementGlobalActorNames: extraction.protocolRequirementGlobalActorNames,
            protocolInheritedProtocolNames: extraction.protocolInheritedProtocolNames,
            globalActorNames: extraction.globalActorNames,
            closureLiteralRecords: extraction.closureLiteralRecords,
            awaitedRanges: extraction.awaitedRanges,
            contentHash: contentHash(of: data)
        )
    }
}
