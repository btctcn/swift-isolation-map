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

    /// A ninth real gap, checked via a real, from-scratch minimal reproduction (a plain macOS SPM
    /// package, `@objc enum LogLevel: Int { case debug, info }` used from a `@MainActor` caller):
    /// `linked.declarations`'s own entry for a **top-level, `@objc`-annotated** enum is keyed by its
    /// *Clang*-style USR (`"c:@M@<Module>@E@<EnumName>"`) -- confirmed exactly,
    /// `"c:@M@MiniObjCEnum@E@LogLevel"` -- not its Swift-mangled form
    /// (`"s:12MiniObjCEnum8LogLevelO"`) `enclosingEnumUSR(forSynthesizedAccessorUSR:)` derives.
    /// `@objc` gives the index store a genuine, dual Clang-side representation for the enum's own
    /// declaration and each of its cases (`"c:@M@<Module>@E@<EnumName>@<EnumName><CaseName>"`, also
    /// confirmed directly) -- `DeclarationLinker`'s own disambiguation, given multiple real
    /// candidates at the enum's declaration site, picks the Clang form over the Swift-mangled one.
    ///
    /// Deliberately scoped to a *top-level* enum only (module immediately followed by one bare type
    /// name, no nested-context prefix) -- a nested `@objc` enum's own Clang USR form has not been
    /// verified against real evidence, so this makes no claim about it, matching this project's own
    /// "no unproven claims" discipline. `enclosingEnumUSR(forSynthesizedAccessorUSR:)`'s own general,
    /// nesting-tolerant Swift-mangled-form derivation is unaffected -- this is a second, independent
    /// candidate to also try, not a replacement.
    public static func enclosingObjCEnumUSR(forSynthesizedAccessorUSR targetUSR: String) -> String? {
        let prefix = "s:"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let moduleName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        for shape in accessorShapes {
            guard remainder.hasPrefix(shape.marker), remainder.hasSuffix(shape.suffix) else { continue }
            return "c:@M@\(moduleName)@E@\(typeName)"
        }
        return nil
    }
}
