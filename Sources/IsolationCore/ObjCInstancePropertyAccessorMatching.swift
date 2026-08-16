import Foundation

/// A class-instance-property sibling to `BridgedExternClassConstantMatching`'s own static-member
/// case: an ordinary Objective-C class's own instance property, accessed from Swift, carries the
/// call graph's own `calleeUSR` in the Swift-mangled accessor form (`"...vg"`/`"...vs"`), but the
/// bulk symbol graph's own `identifier.precise` -- and any live hover -- key an ordinary Clang
/// property by its **selector-style** form (`"c:objc(cs)<TypeName>(py)<MemberName>"`) instead.
///
/// Confirmed real on Project Iris: `UIScene.ConnectionOptions` (`UISceneConnectionOptions` in its
/// own Clang name, a real, confirmed `@MainActor class` per a live `swift symbolgraph-extract`
/// probe) -- `.shortcutItem`'s own call-graph USR,
/// `s:So24UISceneConnectionOptionsC12shortcutItemSo021UIApplicationShortcutE0CSgvg`, has no bulk
/// cache entry under that form, but the real declaration's own precise USR is
/// `c:objc(cs)UISceneConnectionOptions(py)shortcutItem` -- exactly the transformation below
/// produces, confirmed against both `.shortcutItem` and `.userActivities`.
///
/// **Deliberately never parses or validates the return-type mangling at all**, matching
/// `BridgedExternClassConstantMatching`'s own established reasoning -- only the exact `"vg"`/`"vs"`
/// accessor-kind suffix at the very end (never `"vgZ"`/`"vsZ"`, which is
/// `SwiftStaticMemberAccessorDeclarationMatching`'s own, separate static-member case).
public enum ObjCInstancePropertyAccessorMatching {
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

    /// Returns the Clang selector-style declaration USR for a Swift-mangled class instance property
    /// accessor, or `nil` if `targetUSR` isn't shaped like one at all -- including, deliberately, a
    /// *static* member (`"...vgZ"`/`"...vsZ"`, `SwiftStaticMemberAccessorDeclarationMatching`'s own
    /// case) and any struct/enum/protocol container (`"V"`/`"O"`/`"P"` marker, not `"C"`).
    public static func declarationUSR(forInstancePropertyAccessorUSR targetUSR: String) -> String? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("C") else { return nil }
        remainder = remainder.dropFirst(1)
        guard let memberName = readLengthPrefixedIdentifier(&remainder), !memberName.isEmpty else { return nil }
        guard remainder.hasSuffix("vg") || remainder.hasSuffix("vs") else { return nil }
        return "c:objc(cs)\(typeName)(py)\(memberName)"
    }
}
