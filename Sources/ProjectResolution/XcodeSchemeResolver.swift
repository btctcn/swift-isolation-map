import Foundation

public enum XcodeSchemeResolverError: Error, Equatable {
    case notAnXcodeContainer
    case workspaceContentsNotFound(URL)
    case noSchemesFound
    case noMatch(requested: String, available: [String])
}

/// Architecture spec section 2.5: only *shared* schemes are used (`xcshareddata/xcschemes/*.xcscheme`,
/// committed to the repo), never user-specific schemes under `~/Library/Developer/Xcode/UserData/`.
/// For a `.xcworkspace`, `contents.xcworkspacedata` is parsed first to find nested `.xcodeproj`s,
/// each of which contributes its own shared schemes. `XMLParser` (SAX, event-driven) is used
/// throughout, not a DOM API -- explicitly decided against `XMLDocument`/`SWXMLHash` in the
/// architecture spec for Linux-compat (`swift-corelibs-foundation`) and maintenance reasons.
public struct XcodeSchemeResolver: SchemeResolver {
    let fileSystem: FileSystemQuerying

    public init(fileSystem: FileSystemQuerying = LiveFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func discoverSchemes(in container: ProjectContainer) throws -> [any SchemeLike] {
        let schemeFiles = try sharedSchemeFiles(in: container)
        guard !schemeFiles.isEmpty else { throw XcodeSchemeResolverError.noSchemesFound }
        return try schemeFiles.map { try parseScheme(at: $0) }
    }

    public func resolve(named: String, in container: ProjectContainer) throws -> any SchemeLike {
        let schemes = try discoverSchemes(in: container)
        if let match = schemes.first(where: { $0.name == named }) {
            return match
        }
        throw XcodeSchemeResolverError.noMatch(requested: named, available: schemes.map(\.name))
    }

    // MARK: - Discovering .xcodeproj(s) and their shared scheme files

    private func sharedSchemeFiles(in container: ProjectContainer) throws -> [URL] {
        switch container {
        case .xcodeproj(let projectURL):
            return try sharedSchemeFiles(inProject: projectURL)
        case .xcworkspace(let workspaceURL):
            let projectURLs = try nestedProjectURLs(inWorkspace: workspaceURL)
            return try projectURLs.flatMap { try sharedSchemeFiles(inProject: $0) }
        case .swiftPackage:
            throw XcodeSchemeResolverError.notAnXcodeContainer
        }
    }

    private func sharedSchemeFiles(inProject projectURL: URL) throws -> [URL] {
        let schemesDirectory = projectURL.appendingPathComponent("xcshareddata/xcschemes")
        guard fileSystem.directoryExists(at: schemesDirectory) else { return [] }
        return try fileSystem.contentsOfDirectory(at: schemesDirectory)
            .filter { $0.pathExtension == "xcscheme" }
    }

    private func nestedProjectURLs(inWorkspace workspaceURL: URL) throws -> [URL] {
        let contentsURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        guard fileSystem.fileExists(at: contentsURL) else {
            throw XcodeSchemeResolverError.workspaceContentsNotFound(contentsURL)
        }
        let data = try fileSystem.readData(at: contentsURL)
        let delegate = WorkspaceContentsParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        let workspaceDirectory = workspaceURL.deletingLastPathComponent()
        return delegate.fileRefLocations.compactMap { location in
            // Locations are prefixed by a container type ("group:", "container:", "self:", ...)
            // followed by a path relative to the workspace's own directory.
            guard let colonIndex = location.firstIndex(of: ":") else { return nil }
            let relativePath = String(location[location.index(after: colonIndex)...])
            guard relativePath.hasSuffix(".xcodeproj") else { return nil }
            return workspaceDirectory.appendingPathComponent(relativePath)
        }
    }

    // MARK: - Parsing one .xcscheme

    private func parseScheme(at schemeURL: URL) throws -> XcodeScheme {
        let data = try fileSystem.readData(at: schemeURL)
        let delegate = SchemeParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        let name = schemeURL.deletingPathExtension().lastPathComponent
        let projectDirectory = schemeURL
            .deletingLastPathComponent() // xcschemes
            .deletingLastPathComponent() // xcshareddata
            .deletingLastPathComponent() // .xcodeproj
        let buildTargets = delegate.buildableReferences.map {
            BuildTarget(targetName: $0.blueprintName, projectPath: projectDirectory)
        }
        return XcodeScheme(name: name, path: schemeURL, isShared: true, buildTargets: buildTargets)
    }
}

/// Captures each `<FileRef location="...">` at the top level of `contents.xcworkspacedata`.
private final class WorkspaceContentsParserDelegate: NSObject, XMLParserDelegate {
    var fileRefLocations: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "FileRef", let location = attributeDict["location"] else { return }
        fileRefLocations.append(location)
    }
}

/// Captures every `BuildableReference` declared inside `<BuildAction>` specifically -- per the
/// architecture spec, `BuildAction` is "the list of targets actually included in the build
/// (needed for analysis scope)"; references inside `TestAction`/`LaunchAction` are deliberately
/// not collected here.
private final class SchemeParserDelegate: NSObject, XMLParserDelegate {
    struct BuildableReference {
        let blueprintName: String
        let referencedContainer: String
    }

    var buildableReferences: [BuildableReference] = []
    private var isInsideBuildAction = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "BuildAction" {
            isInsideBuildAction = true
            return
        }
        guard isInsideBuildAction, elementName == "BuildableReference" else { return }
        guard let blueprintName = attributeDict["BlueprintName"],
              let referencedContainer = attributeDict["ReferencedContainer"] else { return }
        buildableReferences.append(BuildableReference(blueprintName: blueprintName, referencedContainer: referencedContainer))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "BuildAction" {
            isInsideBuildAction = false
        }
    }
}
