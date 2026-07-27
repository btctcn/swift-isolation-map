import Foundation

public struct CursorInfoRequest: Sendable {
    public let sourceFile: String
    public let byteOffset: Int
    public let compilerArguments: [String]

    public init(sourceFile: String, byteOffset: Int, compilerArguments: [String]) {
        self.sourceFile = sourceFile
        self.byteOffset = byteOffset
        self.compilerArguments = compilerArguments
    }
}
