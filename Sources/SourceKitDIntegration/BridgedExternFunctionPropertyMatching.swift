import Foundation

/// A fourth, independently-confirmed real shape `USRMatching`'s own strict equality can never
/// resolve: a Core Foundation opaque-pointer type, exposed to Swift as a `typealias` to its own
/// "toll-free-bridged" class (`typealias CGImageRef = CGImage`), whose real properties
/// (`CGImage.width`, `.height`, `.bitsPerComponent`, ...) are themselves not genuine Objective-C
/// properties at all -- they're plain Clang **C functions** (`CGImageGetWidth(_:)`) the Swift
/// importer bridges into computed-property syntax via `CF_SWIFT_NAME(getter:)`. A real call-graph
/// edge accessing `someImage.width` (written through the `CGImageRef` typealias spelling, the
/// conventional CoreFoundation naming this project's own corpus and SDK headers both use) carries
/// the Swift-mangled `s:So10CGImageRefa5widthSivg` -- but neither `symbolgraph-extract`'s bulk
/// output nor a live `cursorinfo` hover ever key this member that way: both use the bridged
/// function's own real Clang USR, `c:@F@CGImageGetWidth`.
///
/// **Checked via a real, from-scratch minimal reproduction** (the same temporary iOS SPM package +
/// `CursorInfoProbe` executable target already used for
/// `ObjCProtocolPropertyWitnessMatching`, both fully reverted): confirmed `image.width`'s own live
/// hover resolves to `c:@F@CGImageGetWidth`, `declLang: source.lang.objc`,
/// `containerTypeUSR: "$sSo10CGImageRefaD"`, `name: "width"` -- a plain, unattributed
/// `var width: Int { get }`, no isolation attribute of any kind. Only one real property was
/// directly probed; per this type's own design (mirroring `ObjCProtocolPropertyWitnessMatching`'s
/// own reasoning), the member's own name is deliberately never compared, since the query already
/// runs at the exact position the original call-graph edge itself recorded -- only the
/// declaration's own kind (genuinely Clang, genuinely a bridged function) and its container
/// (matching the concrete typealias `targetUSR` itself names) are cross-checked.
///
/// **Real `targetUSR` shape**: `s:So<N><TypeName>a<N2><MemberName><ArbitraryReturnTypeMangling>vg`
/// -- the `"a"` (typealias) marker immediately after `<TypeName>` is the same marker
/// `BridgedExternConstantMatching` also checks, but that type's own parse only ever succeeds for
/// its own literal `"ABvgZ"` (`Self`-returning, static-getter) suffix; this type is checked later in
/// the fallback chain and only ever reached once that attempt has already failed, so there is no
/// real ambiguity between the two despite sharing one marker character. Only `<TypeName>` is ever
/// parsed -- like `ImportedStructMemberMatching`/`ImportedTopLevelConstantMatching`, the return-type
/// mangling in between is never validated, only the exact `"vg"` getter suffix at the very end
/// (every real example observed is get-only; not generalized to a setter beyond the evidence).
public enum BridgedExternFunctionPropertyMatching {
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
    /// this way at all -- including `BridgedExternConstantMatching`'s own `"ABvgZ"`-suffixed shape,
    /// which shares the `"a"` marker but never reaches here (that type's own `select` is checked
    /// first in the fallback chain and claims those USRs directly).
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("a") else { return nil }
        remainder = remainder.dropFirst(1)
        guard let memberName = readLengthPrefixedIdentifier(&remainder), !memberName.isEmpty else { return nil }
        guard remainder.hasSuffix("vg") else { return nil }
        return ParsedTarget(typeName: typeName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// confirmed exactly against the real probe: `"$sSo10CGImageRefaD"`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)aD"
    }

    /// Deliberately never compares the candidate's own name (see this type's own doc comment) --
    /// only that it's genuinely Clang-presented, a bridged *function* specifically (`"c:@F@"`, not
    /// a plain extern constant or an Objective-C method/property), and from the same container the
    /// `targetUSR` itself names.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:@F@")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring this project's other matchers' own shape -- intended to run only after
    /// `USRMatching.select`, `BridgedExternConstantMatching.select`,
    /// `BridgedExternClassConstantMatching.select`, and
    /// `ObjCProtocolPropertyWitnessMatching.select` have all already returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
