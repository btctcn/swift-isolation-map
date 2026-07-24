import Foundation

/// Decodes `swift package describe --type json`'s real output shape (verified empirically against
/// this project's own package before writing this model -- see the commit introducing this file).
/// Deliberately does not model every field SwiftPM emits (`dependencies`, `platforms`,
/// `tools_version`, per-target `c99name`/`module_type`/`target_dependencies`/`product_memberships`,
/// products' associated-value `type`) -- `Decodable` simply ignores keys with no matching property,
/// and none of the omitted fields are needed for scheme/target resolution.
struct SPMPackageDescription: Decodable {
    let name: String
    let path: String
    let products: [SPMProductDescription]
    let targets: [SPMTargetDescription]
}

struct SPMProductDescription: Decodable {
    let name: String
    let targets: [String]
}

struct SPMTargetDescription: Decodable {
    let name: String
    let path: String
    let sources: [String]
    let type: String
}

public enum SwiftPMSchemeResolverError: Error, Equatable {
    case notASwiftPackage
    case describeFailed(exitCode: Int32, standardError: String)
    case invalidDescribeOutput
    case noMatch(requested: String, available: [String])
}

/// SE section 2.5: "SPM has no schemes -- `--scheme` is matched first against products, then
/// against targets as a fallback." Never hand-parses `Package.swift` (it's arbitrary Swift code,
/// per the architecture spec's own explicit warning) -- always goes through the real SwiftPM CLI.
public struct SwiftPMSchemeResolver: SchemeResolver {
    let processRunning: ProcessRunning

    public init(processRunning: ProcessRunning = LiveProcessRunner()) {
        self.processRunning = processRunning
    }

    public func discoverSchemes(in container: ProjectContainer) throws -> [any SchemeLike] {
        let description = try describe(container)
        return schemes(from: description)
    }

    public func resolve(named: String, in container: ProjectContainer) throws -> any SchemeLike {
        let description = try describe(container)
        let allSchemes = schemes(from: description)
        if let match = allSchemes.first(where: { $0.name == named }) {
            return match
        }
        throw SwiftPMSchemeResolverError.noMatch(requested: named, available: allSchemes.map(\.name))
    }

    private func describe(_ container: ProjectContainer) throws -> SPMPackageDescription {
        guard case .swiftPackage(let packageURL) = container else {
            throw SwiftPMSchemeResolverError.notASwiftPackage
        }
        let packageDirectory = packageURL.deletingLastPathComponent()
        let result = try processRunning.run(
            executable: "swift",
            arguments: ["package", "describe", "--type", "json"],
            workingDirectory: packageDirectory
        )
        guard result.exitCode == 0 else {
            throw SwiftPMSchemeResolverError.describeFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let description = try? JSONDecoder().decode(SPMPackageDescription.self, from: data) else {
            throw SwiftPMSchemeResolverError.invalidDescribeOutput
        }
        return description
    }

    private func schemes(from description: SPMPackageDescription) -> [any SchemeLike] {
        let packagePath = URL(fileURLWithPath: description.path)
        let targetsByName = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0) })

        func resolvedScheme(name: String, targetNames: [String]) -> SPMResolvedScheme {
            let matchedTargets = targetNames.compactMap { targetsByName[$0] }
            let buildTargets = matchedTargets.map {
                BuildTarget(targetName: $0.name, projectPath: packagePath)
            }
            let sourcePaths = matchedTargets.flatMap { target in
                target.sources.map {
                    packagePath.appendingPathComponent(target.path).appendingPathComponent($0).path
                }
            }
            return SPMResolvedScheme(name: name, buildTargets: buildTargets, sourcePaths: sourcePaths)
        }

        let productSchemes = description.products.map { resolvedScheme(name: $0.name, targetNames: $0.targets) }
        // Targets are a fallback match, offered only when their name doesn't already collide with
        // a product name -- avoids two differently-scoped schemes claiming the same `--scheme` name.
        let productNames = Set(description.products.map(\.name))
        let targetSchemes = description.targets
            .filter { !productNames.contains($0.name) }
            .map { resolvedScheme(name: $0.name, targetNames: [$0.name]) }
        return productSchemes + targetSchemes
    }
}
