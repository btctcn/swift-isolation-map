import Foundation

/// An eighth real gap, a sibling to `BridgedExternConstantMatching`'s own real, shipped case
/// (`NSAttributedString.Key.font`) -- same typealias-wrapper shape (`"a"` marker,
/// `"ABvgZ"`-suffixed, `Self`-returning static getter), but for a member whose own name uses
/// Swift's real mangling **substitution compression** instead of a plain length-prefixed
/// identifier -- confirmed via a real live-toolchain probe against `URLResourceKey.isDirectoryKey`
/// (`NSURLResourceKey`'s own Swift-bridged form): the real `targetUSR`,
/// `s:So16NSURLResourceKeya011isDirectoryB0ABvgZ`, contains a `"B0"` back-reference component
/// (Swift's own word-compression mangling, referring back to an earlier-seen identifier fragment,
/// almost certainly `"Key"` here) in place of a second plain length-prefixed identifier --
/// `BridgedExternConstantMatching.parse()`'s own strict two-shape grammar (same-module: one
/// length-prefixed identifier then literal `"ABvgZ"`; cross-module: module name, `"E"`, member
/// name, then literal `"ABvgZ"`) has no notion of this compression at all, so it correctly returns
/// `nil` for this shape rather than misparsing it -- explaining why `NSURLResourceKey`'s own
/// members were never resolved by that already-shipped fix.
///
/// **Design, following `ObjCProtocolPropertyWitnessMatching`'s own established reasoning**: rather
/// than teach the existing, shipped, independently-tested `BridgedExternConstantMatching` to parse
/// Swift's general substitution-compression grammar (a nontrivial, open-ended addition risking its
/// own real, working behavior), this sibling type deliberately never parses or compares the
/// member's own name at all -- only the type name (needed for the container-type-USR check) is
/// ever extracted. The query already runs at the exact position the original call-graph edge
/// itself recorded, so the container-type-USR match (exact same discriminator
/// `BridgedExternConstantMatching` itself relies on) plus `declLang`/USR-prefix checks are
/// sufficient -- position-based correctness, not name-based.
///
/// **Real `targetUSR` shape**: `s:So<N><TypeName>a<AnythingAtAll>ABvgZ` -- deliberately never
/// parses what's between the `"a"` marker and the literal `"ABvgZ"` suffix (unlike
/// `BridgedExternConstantMatching`'s own strict two-shape grammar), only requires the suffix be
/// present *somewhere* after the type name.
public enum BridgedExternConstantContainerMatching {
    public struct ParsedTarget: Equatable {
        public let typeName: String
    }

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

    /// Parses `targetUSR` per this type's own doc comment grammar. `nil` for any USR not shaped
    /// this way at all, including -- deliberately -- `BridgedExternConstantMatching`'s own plain,
    /// uncompressed shape (still matched by that type first in the fallback chain; this one is a
    /// pure coverage *widening*, never a replacement).
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("a") else { return nil }
        remainder = remainder.dropFirst(1)
        guard remainder.hasSuffix("ABvgZ") else { return nil }
        return ParsedTarget(typeName: typeName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// the identical formula `BridgedExternConstantMatching.expectedContainerTypeUSR(forTypeName:)`
    /// already uses, confirmed exactly against the real `URLResourceKey` probe:
    /// `"$sSo16NSURLResourceKeyamD"`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)amD"
    }

    /// Deliberately never compares the candidate's own name (see this type's own doc comment) --
    /// only that it's genuinely Clang-presented, a plain extern-constant shape (`"c:@"`, not e.g.
    /// an Objective-C method selector), and from the same container the `targetUSR` itself names.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:@")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring this project's other matchers' own shape -- intended to run only
    /// after `USRMatching.select` and `BridgedExternConstantMatching.select` have both already
    /// returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
