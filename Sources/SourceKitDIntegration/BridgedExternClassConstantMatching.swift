import Foundation

/// A second, independently-confirmed real shape `USRMatching`'s own strict equality can never
/// resolve, sibling to `BridgedExternConstantMatching` (that type's own doc comment covers the
/// original, `NSAttributedString.Key.font`-shaped bridging case) -- a classic Objective-C
/// `extern const <T> <Name>` global constant, exposed to Swift as a `class`/static member
/// *directly on an ordinary class* via `NS_SWIFT_NAME(<Class>.<member>)`, not wrapped in a
/// `NS_TYPED_EXTENSIBLE_ENUM` typealias struct the way `.font` is. Confirmed via a from-scratch,
/// real-toolchain live `cursorinfo` probe against `UITableView.automaticDimension` (real corpus
/// motivating case): the real declaration genuinely *is* `@MainActor` --
/// `symbolGraphJSON`'s own `declarationFragments` show `@MainActor class let automaticDimension:
/// CGFloat` -- so, unlike `ImportedStructMemberMatching`'s raw-C-struct-field case, this shape is
/// **not** a fixed, always-`nonisolated` fact; the real isolation genuinely varies per symbol and
/// must still come from a live query, same as `BridgedExternConstantMatching`'s own case. This
/// type only helps that live query find the *right* candidate once strict-USR equality already
/// failed for a Clang-Module-qualified target -- never a shortcut around the query itself.
///
/// Real corpus confirms this is a broad, common pattern, not a one-off: notification-name and
/// user-info-key constants across `UIResponder`/`UIApplication`/`UISceneConnectionOptions` and
/// others all share the identical grammar (`keyboardWillShowNotification`,
/// `openSettingsURLString`, `didBecomeActiveNotification`, ...).
///
/// **Real USR mangling grammar** (confirmed against `UITableView.automaticDimension` end to end,
/// plus a broad real-corpus sweep of the shape below):
/// ```
/// s:So<N><TypeName>C<N2><MemberName><ArbitraryReturnTypeMangling>vgZ
/// ```
/// Unlike `BridgedExternConstantMatching`'s own grammar (which hardcodes the `"ABvgZ"` suffix
/// literal because `.font`'s own return type is always `Self`), the return type here varies freely
/// (`CGFloat`, `String`, `NSNotification.Name`, ...) -- so this type deliberately never parses or
/// validates the return-type mangling at all, only the exact `"vgZ"` accessor-kind suffix at the
/// very end. Every real example observed is a `class let` (get-only, static) -- no confirmed
/// instance-member or setter case, so this is deliberately scoped to `"vgZ"` only, not generalized
/// beyond the evidence.
///
/// The container-type-USR discriminator mirrors `BridgedExternConstantMatching.
/// expectedContainerTypeUSR(forTypeName:)`'s own real, confirmed pattern, just with the nominal
/// marker changed from `"a"` (typealias-wrapper) to `"C"` (plain class): confirmed exactly against
/// the real probe's own `key.containertypeusr`, `"$sSo11UITableViewCmD"`.
public enum BridgedExternClassConstantMatching {
    public struct ParsedTarget: Equatable {
        public let typeName: String
        public let memberName: String
    }

    /// Identical parsing primitive to `BridgedExternConstantMatching`'s own -- see that type's doc
    /// comment for why this is a strict, fail-soft length-prefixed read, never a partial/best-effort
    /// parse.
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
    /// this way at all -- including, deliberately, `BridgedExternConstantMatching`'s own `"a"`-marker
    /// shape (rejected here by the `"C"` check), so the two types are mutually exclusive, never
    /// double-matching the same real USR.
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)

        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("C") else { return nil }
        remainder = remainder.dropFirst(1)

        guard let memberName = readLengthPrefixedIdentifier(&remainder), !memberName.isEmpty else { return nil }
        guard remainder.hasSuffix("vgZ") else { return nil }
        return ParsedTarget(typeName: typeName, memberName: memberName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// confirmed exactly against the real `UITableView.automaticDimension` probe:
    /// `"$sSo11UITableViewCmD"`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)CmD"
    }

    /// Same four-part criterion as `BridgedExternConstantMatching.matches(candidate:target:)`, for
    /// this shape's own `expectedContainerTypeUSR`.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.name == target.memberName
            && candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:@")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring `BridgedExternConstantMatching.select(from:targetUSR:)`'s own shape --
    /// intended to run only after both `USRMatching.select` and `BridgedExternConstantMatching.select`
    /// have already returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
