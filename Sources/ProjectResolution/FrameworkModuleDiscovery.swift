import Foundation

/// A real, extractable module discovered from the project's own build configuration -- `name` is
/// the module's *real* name (as `swift symbolgraph-extract -module-name` needs it), `extractionFlags`
/// are the additional compiler flags (`-F <path>` or `-I <path>`) needed to locate it, beyond the
/// SDK/target every extraction already gets.
public struct DiscoveredModule: Equatable, Sendable {
    public let name: String
    public let extractionFlags: [String]

    public init(name: String, extractionFlags: [String]) {
        self.name = name
        self.extractionFlags = extractionFlags
    }
}

/// Discovers real, extractable third-party modules from a project's own `FRAMEWORK_SEARCH_PATHS`
/// -- confirmed empirically against `~/ios` that each CocoaPods/XCFramework dependency gets its own
/// directory there. This is *additive* to Apple's own SDK frameworks (UIKit/AppKit/SwiftUI): those
/// aren't separate directories here at all (implicitly available via `-sdk` alone), so they're
/// still extracted via the existing hardcoded well-known-module list, unaffected by this type.
enum FrameworkModuleDiscovery {
    /// For each `.framework` bundle found directly under any of `frameworkSearchPaths`, resolves
    /// its real module name and returns a `DiscoveredModule` carrying `-F <searchPath>` as its
    /// extraction flag. A framework whose real name can't be determined (no `Modules/*.swiftmodule`
    /// directory and no parseable `Modules/module.modulemap`) is skipped, not guessed -- correct
    /// behavior, since the absence of any Swift module descriptor means there's nothing with
    /// isolation attributes to extract anyway (an ObjC-only framework, irrelevant to this feature).
    static func discoverFrameworks(inSearchPaths frameworkSearchPaths: [String], fileSystem: FileSystemQuerying) -> [DiscoveredModule] {
        var discovered: [DiscoveredModule] = []
        for searchPath in frameworkSearchPaths {
            let searchPathURL = URL(fileURLWithPath: searchPath)
            guard fileSystem.directoryExists(at: searchPathURL) else { continue }
            guard let entries = try? fileSystem.contentsOfDirectory(at: searchPathURL) else { continue }
            for entry in entries where entry.pathExtension == "framework" {
                guard let name = realModuleName(ofFrameworkAt: entry, fileSystem: fileSystem) else { continue }
                discovered.append(DiscoveredModule(name: name, extractionFlags: ["-F", searchPath]))
            }
        }
        return discovered
    }

    /// A framework's directory basename is not a reliable module name -- confirmed empirically:
    /// the real directory `ActionSheetPicker-3.0` (a dash, not a valid Swift identifier) contains
    /// `ActionSheetPicker_3_0.framework` (real name, underscores). Preference order, per review:
    /// a `Modules/<Name>.swiftmodule` directory is authoritative (its name *is* the real module
    /// name, no parsing needed) -- checked first. `Modules/module.modulemap`'s
    /// `framework module <Name> {` line is the fallback for frameworks that only ship a modulemap.
    /// Neither present means no Swift module to extract -- returns `nil`, not a guessed name.
    static func realModuleName(ofFrameworkAt frameworkURL: URL, fileSystem: FileSystemQuerying) -> String? {
        let modulesURL = frameworkURL.appendingPathComponent("Modules")
        if let entries = try? fileSystem.contentsOfDirectory(at: modulesURL) {
            if let swiftmoduleDirectory = entries.first(where: { $0.pathExtension == "swiftmodule" }) {
                return swiftmoduleDirectory.deletingPathExtension().lastPathComponent
            }
        }
        let modulemapURL = modulesURL.appendingPathComponent("module.modulemap")
        guard let data = try? fileSystem.readData(at: modulemapURL), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return moduleName(fromModulemapText: text)
    }

    /// Parses `framework module <Name> {` (or plain `module <Name> {`) from real `module.modulemap`
    /// text -- a small, targeted parse (not a full Clang modulemap grammar), sufficient for the one
    /// line every real framework modulemap has near its start.
    static func moduleName(fromModulemapText text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["framework module ", "module "] {
                guard trimmed.hasPrefix(prefix) else { continue }
                let rest = trimmed.dropFirst(prefix.count)
                let name = rest.prefix(while: { !$0.isWhitespace })
                guard !name.isEmpty else { continue }
                return String(name)
            }
        }
        return nil
    }
}
