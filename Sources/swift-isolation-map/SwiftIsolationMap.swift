import ArgumentParser
import Foundation

enum OutputFormatOption: String, ExpressibleByArgument, CaseIterable {
    case mermaid
    case dot
    case json
}

@main
struct SwiftIsolationMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-isolation-map",
        abstract: "Static actor isolation and data-race analysis for Swift projects."
    )

    @Argument(help: "Path to a .xcodeproj, .xcworkspace, or Package.swift")
    var path: String

    @Option(help: "Build scheme (Xcode) or product/target (SPM). Required.")
    var scheme: String

    @Option(help: "Explicit path to the index store. If provided, auto-detection is skipped.")
    var indexStorePath: String?

    @Flag(help: "If the index store is missing or stale, build the project without an interactive prompt.")
    var autoBuild: Bool = false

    @Flag(help: "Forces a rebuild, ignoring any existing (even fresh) index store.")
    var forceReindex: Bool = false

    @Option(help: "Output format: mermaid | dot | json")
    var output: OutputFormatOption = .mermaid

    @Option(help: "Where to write the result (default: stdout)")
    var outFile: String?

    @Flag(help: "Verbose logging: what was searched, where the index store was found, how many types were processed.")
    var verbose: Bool = false

    func run() throws {
        print("swift-isolation-map: not yet implemented")
    }
}
