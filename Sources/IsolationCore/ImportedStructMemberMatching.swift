import Foundation

/// Fallback matching for a real, confirmed gap `BulkSymbolGraphExtractor` can never resolve by
/// construction: a field/constant of a plain Objective-C/C struct imported directly from a Clang
/// module (`CGSize.width`, `CGRect.origin`, `UIEdgeInsets.top`, `UIControlState.disabled`, ...) has
/// no entry in `swift symbolgraph-extract`'s own output at all -- confirmed directly against a real
/// `CoreGraphics` extraction: neither `CGSize` itself nor any of its `width`/`height` fields appear
/// anywhere in `CoreGraphics.symbols.json`/`CoreGraphics@CoreFoundation.symbols.json`, unlike genuine
/// Swift-authored extension members on the same type (`CGSize.applying(_:)`, `CGSize.zero`'s sibling
/// shape with an explicit `<Module>E` marker -- see below), which do appear normally. `symbolgraph-
/// extract` only enumerates genuinely Swift-visible API surface; a raw imported C struct's own
/// fields are synthesized wrapper accessors around C storage, invisible to it.
///
/// This is never ambiguous the way an unresolved *Swift* declaration can be: a field of a plain
/// Objective-C/C struct is categorically outside Swift's attribute system for its own original
/// declaration -- there is no possible world where `CGSize.width` carries `@MainActor`. Unlike
/// `SynthesizedEnumAccessorMatching` (which still needs a `linked.declarations` membership check
/// because an *enum* name could coincidentally collide with something else), matching this grammar
/// at all is sufficient here -- the real safety net is the grammar's own discriminator (below), which
/// only accepts the "no Swift extension involved" shape.
public enum ImportedStructMemberMatching {
    /// The real Swift USR mangling grammar (confirmed against every field of `CGSize`/`CGRect`/
    /// `CGPoint`/`UIEdgeInsets` and every static case of `UIControlState`/`UIControlEvents` observed
    /// on a real corpus):
    /// ```
    /// s:So<N><TypeName>V<N2><MemberName><ReturnTypeMangling>vg   // instance getter
    /// s:So<N><TypeName>V<N2><MemberName><ReturnTypeMangling>vs   // instance setter
    /// s:So<N><TypeName>V<N2><MemberName>ABvgZ                    // static getter (e.g. .zero, .disabled)
    /// ```
    /// The discriminator against a genuine Swift-authored extension member on the same imported type
    /// (`CGSize.applying(_:)`, mangled `s:So6CGSizeV12CoreGraphicsE8applying...`) is the presence of
    /// a `<M><ModuleName>E` component immediately after the type name's own `V` marker -- a raw
    /// struct field has no such component, going directly from `V` into its own length-prefixed
    /// member name.
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

    /// Returns the USR of the imported struct a raw field/constant access USR belongs to, or `nil`
    /// if `targetUSR` isn't shaped like one at all (the overwhelmingly common case -- including every
    /// genuine Swift-authored extension member on the same or a different imported type).
    public static func containerUSR(forPossibleMemberUSR targetUSR: String) -> String? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("V") else { return nil }
        remainder = remainder.dropFirst(1)
        var memberProbe = remainder
        guard let memberName = readLengthPrefixedIdentifier(&memberProbe), !memberName.isEmpty else { return nil }
        // A Swift extension member's mangling continues with an "E"-terminated module-extension
        // marker right here instead of the member's own accessor suffix -- reject, this isn't a raw
        // struct field.
        guard !memberProbe.hasPrefix("E") else { return nil }
        guard memberProbe.hasSuffix("vg") || memberProbe.hasSuffix("vs") || memberProbe.hasSuffix("vgZ") || memberProbe.hasSuffix("vsZ") else {
            return nil
        }
        return "\(prefix)\(typeName.utf8.count)\(typeName)V"
    }
}
