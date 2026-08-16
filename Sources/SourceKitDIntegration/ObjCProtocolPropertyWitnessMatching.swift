import Foundation

/// A third, independently-confirmed real shape `USRMatching`'s own strict equality can never
/// resolve, but structurally distinct from `BridgedExternConstantMatching`'s and
/// `BridgedExternClassConstantMatching`'s own cases (both of which parse a *Swift-mangled*
/// `s:So...` `targetUSR`): here `targetUSR` is already a **plain Clang selector USR** on a
/// *concrete* class -- `c:objc(cs)UITextField(im)setKeyboardType:` (motivating real corpus case,
/// `UITextField.keyboardType`) -- for a property/method the concrete class doesn't declare itself
/// at all, only *witnesses* via conformance to an Objective-C protocol
/// (`UITextField: UITextInputTraits`). `symbolgraph-extract`'s own bulk output, and a live
/// `cursorinfo` hover at the exact call site, both key such a member by its **protocol-declared**
/// USR (`c:objc(pl)UITextInputTraits(py)keyboardType`) -- never by the concrete witnessing class's
/// own selector-qualified form the call graph's `calleeUSR` actually carries.
///
/// **Checked via a real, from-scratch minimal reproduction (a temporary iOS SPM package + a
/// temporary `CursorInfoProbe` executable target, both fully reverted -- no trace in this diff),
/// not assumed**: confirmed across three independent real properties spanning two unrelated
/// protocols (`UITextInputTraits.keyboardType` get/set, `UITextInputTraits.secureTextEntry`
/// get/set, `UIKeyInput.hasText` get-only) that hovering the *exact* real call-graph edge location
/// always resolves to the protocol-declared candidate, genuinely `@MainActor` in every case
/// observed (UIKit's real convention for `UITextInputTraits`/`UIKeyInput`) -- but, critically, the
/// live-hovered candidate's own `key.name` is **not reliably derivable from the concrete class's
/// selector text** the way `BridgedExternClassConstantMatching`'s own class-marker case is: a
/// setter selector's ordinary `"set" + Capitalized + ":"` stripping (`setSecureTextEntry:` ->
/// `secureTextEntry`) does **not** always match the real Swift-visible property name
/// (`isSecureTextEntry`, confirmed at a real setter call site's own live hover -- Objective-C's
/// own `is`-prefixed boolean-getter/plain-setter naming asymmetry). This type therefore
/// deliberately never parses or compares the member's own name at all -- the query already runs at
/// the exact position the original call-graph edge itself recorded, which sourcekitd and the
/// index-store's own occurrence necessarily agree describes the *same* declaration; only the
/// declaration's own kind (genuinely Clang, genuinely a protocol member) and its container
/// (matching the concrete type `targetUSR` itself names) are cross-checked, not its name.
///
/// **Real `targetUSR` shape**: `c:objc(cs)<TypeName>(im)<AnySelector>` -- deliberately never
/// parses `<AnySelector>` at all, for the reason above; only `<TypeName>` (needed for the
/// container-type-USR check) is extracted.
///
/// **The container-type-USR discriminator's own real shape**, confirmed against the real probe --
/// `"$sSo11UITextFieldCD"` -- is a *different* suffix (`"D"`, a nominal type descriptor reference
/// for an *instance* member) from `BridgedExternClassConstantMatching`'s own `"CmD"` (a *static*
/// member's metatype accessor), consistent with every real example here being an instance
/// property, never a static/class one.
public enum ObjCProtocolPropertyWitnessMatching {
    public struct ParsedTarget: Equatable {
        public let typeName: String
    }

    /// Parses `targetUSR` per this type's own doc comment grammar. `nil` for any USR not shaped
    /// this way at all -- including, deliberately, a project-local Clang-Module-qualified selector
    /// (`c:@CM@<Module>@objc(cs)...`/`c:@M@<Module>@objc(cs)...`, `RawIndexStoreClient`'s own
    /// existing domain), since this type's own real, confirmed cases are all real external SDK
    /// classes with no such qualifier.
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "c:objc(cs)"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        let remainder = targetUSR.dropFirst(prefix.count)
        guard let openParenIndex = remainder.firstIndex(of: "("), remainder[openParenIndex...].hasPrefix("(im)") else {
            return nil
        }
        let typeName = String(remainder[remainder.startIndex..<openParenIndex])
        guard !typeName.isEmpty else { return nil }
        let selector = remainder[remainder.index(openParenIndex, offsetBy: 4)...]
        guard !selector.isEmpty else { return nil }
        return ParsedTarget(typeName: typeName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// confirmed exactly against the real probe: `"$sSo11UITextFieldCD"`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)CD"
    }

    /// Deliberately never compares the candidate's own name (see this type's own doc comment) --
    /// only that it's genuinely Clang-presented, a protocol's own property member, and from the
    /// same container the `targetUSR` itself names.
    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.declLang == "source.lang.objc"
            && candidate.usr.hasPrefix("c:objc(pl)")
            && candidate.usr.contains("(py)")
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring `BridgedExternConstantMatching.select(from:targetUSR:)`'s own shape --
    /// intended to run only after `USRMatching.select`, `BridgedExternConstantMatching.select`, and
    /// `BridgedExternClassConstantMatching.select` have all already returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
