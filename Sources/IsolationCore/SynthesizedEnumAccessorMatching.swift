import Foundation

/// Fallback matching for a real, confirmed gap `linked.declarations` can never resolve by
/// construction: compiler-synthesized `RawRepresentable.rawValue` / `CaseIterable.allCases`
/// accessors of a raw-value enum have no physical declaration in source at all, so
/// `SyntaxAnalysis.DeclarationExtractor` (syntax-only) can never see them, and the call graph's own
/// `calleeUSR` for a real call site (`somePaymentWay.rawValue`) is always absent from
/// `declarations` -- confirmed via a from-scratch mini reproduction
/// (`s:15MiniAnchorRepro10PaymentWayO8rawValueSSvg`, `enum PaymentWay: String { case card, cash }`).
///
/// Both accessors are deterministic: neither can ever carry a user-written isolation attribute, so
/// whenever the *enclosing enum itself* is a genuine project-local declaration, the accessor's own
/// effective isolation is always `.nonisolated`. This is never assumed from the USR's string shape
/// alone -- callers must additionally confirm `enclosingEnumUSR`'s result is a real
/// `linked.declarations` key before trusting it, matching this project's "a wrong answer is worse
/// than no answer" principle.
public enum SynthesizedEnumAccessorMatching {
    /// The real Swift USR mangling grammar for these two accessors, confirmed against 5+ real
    /// examples spanning both the mini reproduction and `Project Iris`, for both top-level enums
    /// (`s:9Ls_net_ru10PaymentWayO8rawValueSSvg`) and enums nested in a struct
    /// (`s:9Ls_net_ru10FilterDataV6LayoutO8allCasesSayACGvgZ`):
    /// ```
    /// s:<...nominal-context-prefix...><EnumName>O8rawValue<ReturnTypeMangling>vg   // instance getter
    /// s:<...nominal-context-prefix...><EnumName>O8allCases<ReturnTypeMangling>vgZ  // static getter
    /// ```
    /// `"rawValue"`/`"allCases"` are each conveniently 8 UTF-8 characters, so both use the literal
    /// length-prefix marker (`"8rawValue"`/`"8allCases"`); the enum's own USR is exactly the
    /// substring of `targetUSR` up to and including the marker's own leading `"O"`.
    private static let accessorShapes: [(marker: String, suffix: String)] = [
        ("O8rawValue", "vg"),
        ("O8allCases", "vgZ"),
    ]

    /// Returns the USR of the enum a synthesized `rawValue`/`allCases` accessor USR belongs to, or
    /// `nil` if `targetUSR` isn't shaped like one at all (the overwhelmingly common case).
    ///
    /// A plain substring search (not a full length-prefixed parse of the nominal-context prefix,
    /// unlike `BridgedExternConstantMatching`) is deliberate and safe here: the real safety net is
    /// the caller's own `linked.declarations` membership check, not the string shape alone -- a
    /// pathological false-positive substring match can only ever produce a USR no real declaration
    /// owns, and therefore have zero effect.
    public static func enclosingEnumUSR(forSynthesizedAccessorUSR targetUSR: String) -> String? {
        guard targetUSR.hasPrefix("s:") else { return nil }
        for shape in accessorShapes {
            guard let markerRange = targetUSR.range(of: shape.marker), targetUSR.hasSuffix(shape.suffix) else { continue }
            let enumUSREnd = targetUSR.index(after: markerRange.lowerBound)
            return String(targetUSR[targetUSR.startIndex..<enumUSREnd])
        }
        return nil
    }
}
