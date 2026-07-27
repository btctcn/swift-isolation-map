import Foundation
import ProjectResolution

enum UTF8OffsetLocatorError: Error, Equatable {
    case fileNotReadable(String)
    case lineOutOfRange(file: String, line: Int)
}

/// Converts a 1-based `(line, UTF-8-byte column)` location -- already this project's own
/// declaration/call-graph location convention, confirmed to match IndexStoreDB's directly (see
/// `DeclarationLinker.swift`'s doc comment) -- into an absolute UTF-8 byte offset from the start
/// of the file, the form `sourcekitd`'s `key.offset` requires. This conversion didn't exist
/// anywhere in the codebase before Phase C (every prior consumer of `SymbolLocation` only needed
/// line/column, never a flat file offset).
enum UTF8OffsetLocator {
    static func utf8Offset(inFile path: String, line: Int, utf8Column: Int, fileSystem: FileSystemQuerying) throws -> Int {
        guard let data = try? fileSystem.readData(at: URL(fileURLWithPath: path)) else {
            throw UTF8OffsetLocatorError.fileNotReadable(path)
        }
        var offset = 0
        var currentLine = 1
        var index = data.startIndex
        while currentLine < line {
            guard let newlineIndex = data[index...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw UTF8OffsetLocatorError.lineOutOfRange(file: path, line: line)
            }
            offset += data.distance(from: index, to: newlineIndex) + 1
            index = data.index(after: newlineIndex)
            currentLine += 1
        }
        return offset + (utf8Column - 1)
    }
}
