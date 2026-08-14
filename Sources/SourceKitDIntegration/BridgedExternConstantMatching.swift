import Foundation

/// Fallback matching for a real, confirmed shape `USRMatching`'s own strict equality can never
/// resolve by construction (docs/task-extern-constant-swift-name-usr-mismatch.md, §§1-16 for the
/// full investigation): a classic Objective-C `extern NSString *const` global constant, exposed to
/// Swift as a static member of a bridged wrapper type via `NS_EXTENSIBLE_STRING_ENUM`/
/// `NS_TYPED_EXTENSIBLE_ENUM` + `NS_SWIFT_NAME` (`NSAttributedString.Key.font` is the real,
/// motivating example; confirmed to generalize to any Objective-C library using the same pattern,
/// not an Apple-SDK quirk -- §16's from-scratch, non-Apple mini reproduction).
///
/// The real compiler's own `IndexStoreDB`-derived call graph records the Swift-bridged USR
/// (`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`) as `targetUSR` -- but a live `cursorinfo` query
/// at the real call site only ever resolves through the original Clang declaration
/// (`c:@NSFontAttributeName`), never the Swift-bridged one (confirmed directly, §8/§16's real
/// `sourcekitd` dumps: `key.decl_lang: source.lang.objc` every time). No live sourcekitd/libIndexStore
/// query this project's own binding design permits ever produces the Swift-bridged USR for this shape
/// (§§10-14's six independently exhausted attempts) -- `USRMatching`'s strict equality can only ever
/// return `nil` here, `.unknown`, never a false answer, but also never the real, knowable one.
///
/// This type never trusts the Clang constant's own *name* (`NSFontAttributeName`'s `NS*AttributeName`
/// convention) -- only the declaration's own returned facts, cross-checked against a real, verified
/// parse of the *already-known-correct* `targetUSR`: does the candidate's own `key.name` match the
/// member name `targetUSR` itself encodes, is it genuinely presented from the Clang side
/// (`key.decl_lang == source.lang.objc`, not some unrelated Swift declaration sharing a name), is its
/// own USR a plain Clang top-level/extern-constant shape (`c:@...`, not e.g. an Objective-C method
/// selector), and does its own `key.containertypeusr` match the *same* container type `targetUSR`
/// itself names. All four checks are needed together -- confirmed via a reviewer pass over the first,
/// three-part draft of this criterion (docs/task-extern-constant-swift-name-usr-mismatch.md §15.3's
/// own revision history) that omitting the container-type check leaves the criterion unable to
/// actually confirm *which* type's member is being matched, only that some Clang declaration happens
/// to share a bare member name.
public enum BridgedExternConstantMatching {
    /// The real Swift mangling grammar this whole mechanism depends on, confirmed against 23 real,
    /// independent examples across three real modules (`docs/task-extern-constant-swift-name-usr-
    /// mismatch.md` §15.1's 22-member `NSAttributedString.Key` sweep, plus §16's from-scratch,
    /// non-Apple `MiniAttrKey.font`):
    /// ```
    /// s:So<N><TypeName>a[<M><ModuleName>E]<N2><MemberName>ABvgZ
    /// ```
    /// The `<M><ModuleName>E` component is present only when the member is declared in a *different*
    /// module than the wrapper type itself (`NSAttributedString.Key.font`, declared in `UIKit`,
    /// extending a `Foundation` type) and absent when both live in the same module (§16's
    /// `MiniAttrKey.font`, both in `CMiniAttrs`) -- confirmed empirically, not assumed, by comparing
    /// both real shapes directly. `<N>`/`<M>`/`<N2>` are each the following identifier's own UTF-8
    /// length, Swift's real length-prefixed mangling convention (not a length-prefix improvised for
    /// this task).
    public struct ParsedTarget: Equatable {
        public let typeName: String
        public let memberName: String
    }

    /// Reads one length-prefixed identifier (`<decimal-length><that-many-bytes>`) starting at
    /// `remainder`'s own start, consuming it from `remainder` on success. `nil` (leaving `remainder`
    /// untouched) on any malformed input -- no partial/best-effort parse, matching this project's own
    /// "a wrong answer is worse than no answer" guiding principle.
    private static func readLengthPrefixedIdentifier(_ remainder: inout Substring) -> String? {
        var digitsEnd = remainder.startIndex
        while digitsEnd < remainder.endIndex, remainder[digitsEnd].isASCII, remainder[digitsEnd].isNumber {
            digitsEnd = remainder.index(after: digitsEnd)
        }
        guard digitsEnd > remainder.startIndex, let length = Int(remainder[remainder.startIndex..<digitsEnd]) else {
            return nil
        }
        let identifierStart = digitsEnd
        guard let identifierEnd = remainder.index(identifierStart, offsetBy: length, limitedBy: remainder.endIndex) else {
            return nil
        }
        let identifier = String(remainder[identifierStart..<identifierEnd])
        remainder = remainder[identifierEnd...]
        return identifier
    }

    /// Parses `targetUSR` per this type's own doc comment grammar. `nil` for any USR not shaped this
    /// way at all (the overwhelmingly common case -- most `targetUSR`s are ordinary declarations this
    /// mechanism has no business touching) -- callers must treat `nil` as "this mechanism doesn't
    /// apply here," not as a parse failure worth surfacing.
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)

        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("a") else { return nil }
        remainder = remainder.dropFirst(1)

        // Try the same-module shape first: read one length-prefixed identifier and check whether the
        // exact literal suffix "ABvgZ" immediately follows -- if so, that identifier is the member
        // name itself, no module-extension component present.
        var sameModuleProbe = remainder
        guard let firstIdentifier = readLengthPrefixedIdentifier(&sameModuleProbe) else { return nil }
        let suffix = "ABvgZ"
        if sameModuleProbe == Substring(suffix) {
            return ParsedTarget(typeName: typeName, memberName: firstIdentifier)
        }

        // Otherwise, the cross-module shape: `firstIdentifier` was the module name; expect the
        // extension marker "E", then the real member name, then the exact literal suffix.
        guard sameModuleProbe.hasPrefix("E") else { return nil }
        var crossModuleRemainder = sameModuleProbe.dropFirst(1)
        guard let memberName = readLengthPrefixedIdentifier(&crossModuleRemainder) else { return nil }
        guard crossModuleRemainder == Substring(suffix) else { return nil }
        return ParsedTarget(typeName: typeName, memberName: memberName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// confirmed exactly, byte-for-byte, against three real, independent examples (§15.4/§16):
    /// `NSAttributedString.Key.font`/`.kern` (`"$sSo21NSAttributedStringKeyamD"`) and the from-scratch
    /// `MiniAttrKey.font` (`"$sSo11MiniAttrKeyamD"`).
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)amD"
    }

    /// All four checks together, per this type's own doc comment -- a candidate must satisfy every
    /// one, never a partial/best-guess match.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.name == target.memberName
            && candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:@")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring `USRMatching.select(from:targetUSR:)`'s own shape -- intended to run only
    /// *after* `USRMatching.select` itself has already returned `nil` (this is a narrow fallback for a
    /// confirmed-unmatchable-by-strict-equality shape, never a replacement for strict matching in
    /// general).
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
