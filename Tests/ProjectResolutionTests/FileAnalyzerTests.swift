import Foundation
import Testing
@testable import ProjectResolution

@Test("Analyzing a file yields both the extracted declarations and a content hash from the same read")
func analyzeYieldsDeclarationsAndHash() throws {
    let fileSystem = FakeFileSystem()
    let url = URL(fileURLWithPath: "/project/Sources/Widget.swift")
    let source = "actor Widget {}"
    fileSystem.addFile(at: url, contents: source)

    let analyzer = FileAnalyzer(fileSystem: fileSystem)
    let result = try analyzer.analyze(fileAt: url)

    #expect(result.declarations.contains { $0.name == "Widget" && $0.isActorType })
    #expect(result.contentHash == contentHash(of: Data(source.utf8)))
}

@Test("Analyzing a file also yields its protocolGlobalActorNames, for cross-file linking")
func analyzeYieldsProtocolGlobalActorNames() throws {
    let fileSystem = FakeFileSystem()
    let url = URL(fileURLWithPath: "/project/Sources/Refreshable.swift")
    let source = "@MainActor protocol Refreshable {}"
    fileSystem.addFile(at: url, contents: source)

    let analyzer = FileAnalyzer(fileSystem: fileSystem)
    let result = try analyzer.analyze(fileAt: url)

    #expect(result.protocolGlobalActorNames["Refreshable"] == "MainActor")
}

@Test("Non-UTF8 file content throws rather than silently producing garbage")
func nonUTF8ContentThrows() {
    let fileSystem = FakeFileSystem()
    let url = URL(fileURLWithPath: "/project/Sources/Bad.swift")
    fileSystem.addFile(at: url, contents: Data([0xFF, 0xFE, 0x00, 0xD8]))

    let analyzer = FileAnalyzer(fileSystem: fileSystem)
    #expect(throws: FileAnalysisError.notUTF8(url)) {
        try analyzer.analyze(fileAt: url)
    }
}
