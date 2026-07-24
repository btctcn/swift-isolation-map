import Foundation
@testable import ProjectResolution

/// Records invocations and returns a canned result per (executable, arguments) pair, or throws
/// if none was registered -- keeps CLI-logic tests from ever shelling out for real.
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

    func run(executable: String, arguments: [String], workingDirectory: URL?) throws -> ProcessResult {
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

/// A tiny in-memory filesystem: directories and files are both just entries in a dictionary
/// keyed by absolute path, distinguished by whether they carry `Data` or not.
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
}
