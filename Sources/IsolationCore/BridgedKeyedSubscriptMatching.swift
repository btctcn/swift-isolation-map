import Foundation

/// `NSDictionary`/`NSMutableDictionary["key" as NSCopying]` -- an eighth, real gap
/// (issue #126), structurally adjacent to `SubscriptAccessorDeclarationMatching` (issue #94) but
/// not fixable by that matcher's own "accessor form -> `cip`-suffixed declaration form" rewrite,
/// because no `cip`-suffixed declaration exists for this specific overload anywhere in the bulk
/// symbol-graph cache to rewrite *to*.
///
/// **Why this overload exists at all**: `NSDictionary`/`NSMutableDictionary` expose Cocoa's
/// keyed-subscripting convention directly from their own Objective-C methods --
/// `objectForKeyedSubscript:` (declared on `NSDictionary`, so both classes get a getter) and
/// `setObject:forKeyedSubscript:` (declared on `NSMutableDictionary` only, adding a setter there).
/// ClangImporter synthesizes this pair into a Swift `subscript(key: NSCopying) -> Any? { get
/// [set] }`, distinct from the Swift overlay's own separate, generic `subscript(key: Any) -> Any?
/// { get set }` extension (`SubscriptAccessorDeclarationMatching`'s own subject) -- overload
/// resolution at a real call site picks whichever is more specific for the key's static type, so
/// both shapes occur in real code (confirmed: `Pods/Signals/Signals/ios/UIControl+Signals.swift`'s
/// `dictionary[key]`, `key: String`, resolves to the `NSCopying`-keyed form specifically).
///
/// **Confirmed via a real `symbolgraph-extract -module-name Foundation` dump** (issue #126): unlike
/// the Swift overlay's generic subscript, this ClangImporter-synthesized one is never independently
/// serialized as a Swift-mangled `"cip"`-suffixed declaration at all. Instead, `symbolgraph-extract`
/// represents the *whole* get(+set) pair as one symbol keyed by the getter's own Clang method USR
/// (`c:objc(cs)NSDictionary(im)objectForKeyedSubscript:`), emitted **twice** -- once under
/// `NSDictionary` (`declarationFragments` end `{ get }`) and once under `NSMutableDictionary`
/// (`{ get set }`) -- `setObject:forKeyedSubscript:`'s own selector never appears anywhere in the
/// extracted output as an independent symbol. Both real accessor USRs (getter `"...cig"` and setter
/// `"...cis"`) therefore resolve to that one fixed Clang USR: isolation here is a property of the
/// subscript/its container (`NSDictionary`/`NSMutableDictionary`, both always `.nonisolated`), not
/// of get vs. set individually, so collapsing both accessors onto the getter's own bulk-cache entry
/// loses nothing.
public enum BridgedKeyedSubscriptMatching {
    private static let objectForKeyedSubscriptUSR = "c:objc(cs)NSDictionary(im)objectForKeyedSubscript:"

    /// Returns the bulk-cache USR a `NSCopying`-keyed `NSDictionary`/`NSMutableDictionary`
    /// subscript accessor USR (`"...cig"`/`"...cis"`) corresponds to, or `nil` if `usr` isn't
    /// shaped this way at all. Deliberately requires both the exact `NSCopying`-parameterized,
    /// `Any?`-returning accessor suffix *and* one of the two real container names embedded in the
    /// mangling -- narrow by construction, matching this project's own "don't generalize past what
    /// a real corpus confirmed" discipline (only `NSDictionary`/`NSMutableDictionary` are confirmed
    /// to expose this exact Cocoa keyed-subscripting pair).
    public static func bulkCacheUSR(forAccessorUSR usr: String) -> String? {
        guard usr.hasSuffix("SgSo9NSCopying_pcig") || usr.hasSuffix("SgSo9NSCopying_pcis") else { return nil }
        guard usr.contains("So12NSDictionaryC") || usr.contains("So19NSMutableDictionaryC") else { return nil }
        return objectForKeyedSubscriptUSR
    }
}
