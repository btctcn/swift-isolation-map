import Foundation

/// A narrow sibling to `BridgedExternConstantContainerMatching`, for the identical typealias-wrapper
/// shape but with an **Optional-wrapped** return type instead of a bare `Self`. Confirmed real on
/// Project Iris: `CFRunLoopMode.defaultMode` (`s:So13CFRunLoopModea07defaultC0ABSgvgZ`, real
/// `swift-demangle` output: `"static __C.CFRunLoopMode.defaultMode.getter : __C.CFRunLoopMode?"`) --
/// same `"a"`-marker, same real mangling substitution compression (`"C0"`, this type's own analog of
/// `URLResourceKey`'s `"B0"`) `BridgedExternConstantContainerMatching` was built for, but its own
/// strict `"ABvgZ"` suffix check doesn't match here because the real suffix is `"ABSgvgZ"` --
/// `"Sg"` (Optional) inserted between the `Self` marker (`"AB"`) and the accessor-kind suffix,
/// reflecting the real header's `NS_ASSUME_NONNULL`-scoped nullable return.
///
/// Kept as a separate type rather than widening `BridgedExternConstantContainerMatching`'s own
/// already-shipped, independently-tested suffix check -- consistent with this project's own
/// established precedent (`ObjCProtocolPropertyWitnessMatching`, `BridgedExternConstantContainerMatching`
/// itself) of adding a narrow sibling for a newly-confirmed shape rather than risking a working
/// matcher's own real behavior.
public enum BridgedExternConstantOptionalContainerMatching {
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
    /// this way, including -- deliberately -- both `BridgedExternConstantMatching`'s own plain shape
    /// and `BridgedExternConstantContainerMatching`'s own bare-`Self` shape (still matched by those
    /// two first in the fallback chain; this one is a pure coverage widening for the Optional case).
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("a") else { return nil }
        remainder = remainder.dropFirst(1)
        guard remainder.hasSuffix("ABSgvgZ") else { return nil }
        return ParsedTarget(typeName: typeName)
    }

    /// Identical formula to `BridgedExternConstantContainerMatching.expectedContainerTypeUSR(forTypeName:)`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)amD"
    }

    /// Identical criterion to `BridgedExternConstantContainerMatching.matches(candidate:target:)`.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:@")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring this project's other matchers' own shape -- intended to run only after
    /// `USRMatching.select`, `BridgedExternConstantMatching.select`, and
    /// `BridgedExternConstantContainerMatching.select` have all already returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
