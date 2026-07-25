import Foundation
import IsolationCore
import SyntaxAnalysis

public struct FileAnalysisResult: Equatable, Sendable {
    public let declarations: [DeclarationInfo]
    /// Threaded through from `ExtractionResult` (Priority 2 Phase 3) so a caller linking multiple
    /// files' results (`IndexStoreIntegration.DeclarationLinker`) has what it needs for cross-file
    /// `protocolGlobalActorName` backfill, without a second parse of the same source.
    public let protocolGlobalActorNames: [String: String]
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

    public func analyze(fileAt url: URL) throws -> FileAnalysisResult {
        let data = try fileSystem.readData(at: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw FileAnalysisError.notUTF8(url)
        }
        let extraction = DeclarationExtractor.extractWithContext(source: source, fileName: url.path)
        return FileAnalysisResult(
            declarations: extraction.declarations,
            protocolGlobalActorNames: extraction.protocolGlobalActorNames,
            contentHash: contentHash(of: data)
        )
    }
}
