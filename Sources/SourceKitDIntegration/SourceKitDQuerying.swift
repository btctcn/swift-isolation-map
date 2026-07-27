import Foundation

public enum SourceKitDQueryError: Error, Equatable {
    case loadFailed(String)
    case malformedResponse(String)
    case requestFailed(String)
}

/// Narrow protocol over raw `sourcekitd` cursor-info -- mirrors `IndexStoreQuerying`'s shape
/// (`IndexStoreIntegration/IndexStoreClient.swift`), so downstream orchestration can be tested
/// against a fake without a real toolchain, same precedent.
public protocol SourceKitDQuerying: Sendable {
    func cursorInfo(_ request: CursorInfoRequest) async throws -> CursorInfoResult
}
