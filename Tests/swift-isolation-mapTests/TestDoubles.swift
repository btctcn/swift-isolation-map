import Foundation
@testable import ProjectResolution

/// Same pattern as `ProjectResolutionTests/TestDoubles.swift`'s `FakeProcessRunner` -- kept as a
/// separate copy rather than shared/exported, since `ProjectResolutionTests`'s copy is private to
/// that test target (`@testable import` doesn't re-export test-target-only types).
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Hashable {
        let executable: String
        let arguments: [String]
    }

    private var responses: [Invocation: ProcessResult] = [:]
    private(set) var invocations: [Invocation] = []

    func stub(executable: String, arguments: [String], result: ProcessResult) {
        responses[Invocation(executable: executable, arguments: arguments)] = result
    }

    func run(executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        let invocation = Invocation(executable: executable, arguments: arguments)
        invocations.append(invocation)
        guard let result = responses[invocation] else {
            throw NSError(domain: "FakeProcessRunner", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No stubbed response for \(executable) \(arguments)"
            ])
        }
        return result
    }
}

/// Same pattern as `ProjectResolutionTests/TestDoubles.swift`'s `FakeFileSystem` -- kept as a
/// separate copy for the same reason as `FakeProcessRunner` above (test-target-only types aren't
/// re-exported by `@testable import`).
final class FakeFileSystem: FileSystemQuerying, @unchecked Sendable {
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []

    func addFile(at url: URL, contents: Data) {
        files[url.path] = contents
        markDirectoriesExisting(for: url.deletingLastPathComponent())
    }

    func addFile(at url: URL, contents: String) {
        addFile(at: url, contents: Data(contents.utf8))
    }

    func addDirectory(at url: URL) {
        markDirectoriesExisting(for: url)
    }

    private func markDirectoriesExisting(for url: URL) {
        var current = url
        while current.path != "/" && !current.path.isEmpty {
            directories.insert(current.path)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
    }

    func fileExists(at url: URL) -> Bool {
        files[url.path] != nil
    }

    func directoryExists(at url: URL) -> Bool {
        directories.contains(url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var children: Set<String> = []
        for path in files.keys where path.hasPrefix(prefix) {
            let remainder = String(path.dropFirst(prefix.count))
            if let firstComponent = remainder.split(separator: "/").first {
                children.insert(prefix + firstComponent)
            }
        }
        for path in directories where path.hasPrefix(prefix) && path != url.path {
            let remainder = String(path.dropFirst(prefix.count))
            if let firstComponent = remainder.split(separator: "/").first,
               !remainder.contains("/") || remainder == firstComponent {
                children.insert(prefix + firstComponent)
            }
        }
        return children.map { URL(fileURLWithPath: $0) }
    }

    func readData(at url: URL) throws -> Data {
        guard let data = files[url.path] else {
            throw NSError(domain: "FakeFileSystem", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No file at \(url.path)"
            ])
        }
        return data
    }

    func write(data: Data, to url: URL) throws {
        addFile(at: url, contents: data)
    }
}
