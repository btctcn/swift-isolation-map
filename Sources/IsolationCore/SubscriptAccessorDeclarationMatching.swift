import Foundation

/// A seventh, structurally distinct real gap, and the first in this whole investigation that's
/// pure Swift-to-Swift (`declLang: source.lang.swift`, no Clang bridging at all): a call-graph
/// edge accessing a Swift-declared `subscript` on an imported Clang class (`NSDictionary["key"]`,
/// `NSMutableDictionary["key"] = value`) carries the specific *accessor's* own USR
/// (`...cig`/`...cis`, the real Swift mangling suffix for a subscript's getter/setter), but both
/// `symbolgraph-extract`'s bulk output and a live `cursorinfo` hover key the *same* subscript by
/// its own **declaration** USR (`...cip`) instead -- never the accessor-specific form.
///
/// **Checked via a real, from-scratch minimal reproduction** (a plain macOS Swift file + a direct
/// `cursorinfo` probe against the actual toolchain, no Xcode project needed since `NSDictionary`
/// needs no iOS-specific SDK surface): confirmed both `NSDictionary["key"]` (get) and
/// `NSMutableDictionary["key"] = value` (set) hover to `s:So12NSDictionaryC10FoundationEyypSgypcip`/
/// `s:So19NSMutableDictionaryC10FoundationEyypSgypcip` respectively -- the exact `"cip"`-suffixed
/// declaration form, plain `@objc dynamic subscript(_:) -> Any? { get set }`, no isolation
/// attribute at all.
///
/// **Real USR mangling grammar**: Swift's own subscript-accessor mangling always ends `"cig"`
/// (getter) or `"cis"` (setter) where the declaration itself ends `"cip"` -- confirmed identical
/// for both real examples above, differing only in the final letter. Deliberately requires this
/// *exact* three-character suffix (never a bare trailing `"g"`/`"s"` alone, which every ordinary
/// property getter/setter also ends in) -- the `"ci"` component is what specifically marks a
/// *subscript* accessor, not any other kind.
///
/// Unlike this project's five other external-isolation matchers (which parse Clang-selector or
/// Clang-bridged-constant shapes), this one only ever needs the bulk cache -- the declaration form
/// is already correctly keyed there (Foundation is a default bulk module), so once the accessor
/// form is recognized and rewritten, a plain dictionary lookup answers it, no live query at all.
public enum SubscriptAccessorDeclarationMatching {
    /// Returns the subscript *declaration* USR (`"cip"`-suffixed) a subscript *accessor* USR
    /// (`"cig"`/`"cis"`-suffixed) corresponds to, or `nil` if `usr` isn't shaped this way at all --
    /// the overwhelmingly common case, including every ordinary property accessor (which never
    /// carries the `"ci"` subscript marker immediately before its own final letter).
    public static func subscriptDeclarationUSR(forAccessorUSR usr: String) -> String? {
        guard usr.hasSuffix("cig") || usr.hasSuffix("cis") else { return nil }
        return String(usr.dropLast()) + "p"
    }
}
