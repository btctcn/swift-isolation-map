import Foundation
import ProjectResolution

/// Closes the "known, deliberately accepted limitation" `MultiTargetDeclarationAliasing` explicitly
/// called out in its own doc comment: two sibling-target variants of the *same* physical declaration
/// (docs/task-multi-target-declaration-aliasing.md's own shape) can have their real, module-stripped
/// mangled *suffixes* diverge even though the underlying declaration is identical, because Swift's
/// own mangling substitution compression is sensitive to what identifiers already appeared earlier
/// in the *same* mangled string -- which the module name (differing per target) is part of. Real,
/// confirmed on `Project Iris`: `CurrentNotifications.removeOldNotifications`, compiled under three
/// separate targets, mangles as `07CurrentB0C...` under one module (compressed) and
/// `20CurrentNotificationsC...` under the other two (uncompressed) -- `MultiTargetDeclarationAliasing`'s
/// own byte-for-byte suffix comparison correctly (never a false positive) fails to alias it, staying
/// unresolved rather than guessing.
///
/// Rather than re-deriving Swift's real substitution-compression algorithm here (real risk of a
/// subtly wrong reimplementation producing a false-positive alias -- exactly what this project's own
/// "never guess" discipline exists to prevent), this defers to the real, authoritative demangler
/// (`swift-demangle`, part of the same toolchain already relied on elsewhere in this project) and
/// compares its **module-agnostic, discriminator-stripped** output instead -- immune to compression
/// by construction, since a demangled name is the fully-expanded human-readable form.
///
/// Confirmed via a real `swift-demangle` invocation against all three of `CurrentNotifications
/// .removeOldNotifications`'s own real USRs from Project Iris: all three demangle to
/// `lsboutiqueContentExtension_Release.CurrentNotifications.(removeOldNotifications in _<hash>)() -> ()`
/// (etc, one per target) -- identical once the leading module-name component and the trailing
/// `(name in _<hash>)` private-discriminator annotation (a real, per-compiled-unit-varying hash,
/// confirmed to differ across all three targets even for the identical physical declaration -- never
/// meaningfully comparable across targets, unlike the rest of the signature) are both stripped.
public enum DemangledSiblingMatching {
    /// Keeps a single `swift-demangle` invocation's argument list comfortably under any real OS
    /// `ARG_MAX`, batching the overwhelming majority of a real corpus into a handful of subprocess
    /// calls rather than one per declaration.
    static let chunkSize = 1000

    private static let discriminatorPattern = try! NSRegularExpression(pattern: #"\(([A-Za-z0-9_]+) in _[0-9A-Fa-f]+\)"#)

    /// Demangles a batch of Swift-mangled USRs (the literal `usr` string, `"s:"`-prefixed) via real
    /// `swift-demangle` invocations, and returns each recognized USR's own **raw, unstripped**
    /// demangled text -- e.g. `"__C.CGSize.width.getter : Swift.Double"` or, for a genuine Swift
    /// extension member, `"(extension in CoreGraphics):__C.CGSize.isEmpty.getter : Swift.Bool"`. A
    /// USR `swift-demangle` doesn't recognize (echoed back unchanged, confirmed real behavior) is
    /// simply absent from the result -- never guessed. `moduleAgnosticSignatures(forSwiftUSRs:)`
    /// below builds on this; `DemangledStructMemberMatching` uses the raw form directly, since
    /// stripping the module-name-like leading component would destroy the exact
    /// `"(extension in "` vs. plain `"__C."` distinction it depends on.
    public static func rawDemangled(forSwiftUSRs usrs: [String], processRunning: ProcessRunning) -> [String: String] {
        var results: [String: String] = [:]
        var index = 0
        while index < usrs.count {
            let chunk = Array(usrs[index..<min(index + chunkSize, usrs.count)])
            index += chunkSize
            let mangledInputs = chunk.map { "$s" + $0.dropFirst("s:".count) }
            guard let output = try? processRunning.run(executable: "xcrun", arguments: ["swift-demangle"] + mangledInputs, workingDirectory: nil, timeout: 60),
                  output.exitCode == 0 else {
                continue
            }
            let lines = output.standardOutput.split(separator: "\n", omittingEmptySubsequences: true)
            // `swift-demangle` emits exactly one output line per input argument, in the same order
            // -- confirmed real behavior, including for unrecognized input (echoed back verbatim
            // with its own `--->` arrow, never dropped or merged) -- so positional zipping against
            // `chunk` is safe and avoids re-parsing the arrow-prefixed mangled name back into a USR.
            for (usr, line) in zip(chunk, lines) {
                guard let arrowRange = line.range(of: " ---> ") else { continue }
                results[usr] = String(line[arrowRange.upperBound...])
            }
        }
        return results
    }

    /// Module-agnostic, discriminator-stripped comparable signature for every recognized USR -- see
    /// `rawDemangled(forSwiftUSRs:processRunning:)` for the underlying batching/parsing.
    public static func moduleAgnosticSignatures(forSwiftUSRs usrs: [String], processRunning: ProcessRunning) -> [String: String] {
        rawDemangled(forSwiftUSRs: usrs, processRunning: processRunning).compactMapValues { moduleAgnosticSignature(fromDemangled: $0) }
    }

    /// Extracts the bare member/type name from a `moduleAgnosticSignatures(forSwiftUSRs:)` signature
    /// -- the last identifier component before any parameter list or type annotation. Used purely to
    /// narrow which already-linked declarations are worth demangling as alias candidates in the
    /// first place (matched against their own cheap, already-extracted `DeclarationInfo.name`, no
    /// demangling needed for the narrowing itself) -- never the actual comparison, which always
    /// compares two full `moduleAgnosticSignatures(forSwiftUSRs:)` results. A wrong or missed narrow
    /// only means a real alias is missed (falls through to unresolved, same as today), never a false
    /// positive.
    public static func bareMemberName(fromSignature signature: String) -> String? {
        let stopCharacters = CharacterSet(charactersIn: "(: ")
        let firstStop = signature.rangeOfCharacter(from: stopCharacters)
        let head = firstStop.map { String(signature[..<$0.lowerBound]) } ?? signature
        guard let lastDot = head.lastIndex(of: ".") else { return head.isEmpty ? nil : head }
        let name = String(head[head.index(after: lastDot)...])
        return name.isEmpty ? nil : name
    }

    private static func moduleAgnosticSignature(fromDemangled demangled: String) -> String? {
        guard let dotIndex = demangled.firstIndex(of: ".") else { return nil }
        let withoutModule = String(demangled[demangled.index(after: dotIndex)...])
        let range = NSRange(withoutModule.startIndex..., in: withoutModule)
        return discriminatorPattern.stringByReplacingMatches(in: withoutModule, range: range, withTemplate: "$1")
    }
}
