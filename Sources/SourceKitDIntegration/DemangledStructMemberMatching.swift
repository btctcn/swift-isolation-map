import Foundation
import ProjectResolution

/// A sibling to `IsolationCore.ImportedStructMemberMatching`, for a raw C struct field whose own
/// name uses Swift's real compound/underscore-identifier mangling scheme instead of that type's own
/// simple length-prefixed identifier parse. Confirmed real on Project Iris:
/// `_firebase_appquality_sessions_SessionInfo.firebase_installation_id` (a nanopb-generated C struct
/// field, snake_case name -- common across any protobuf-generated C struct, not a one-off) mangles
/// as `s:So41..._SessionInfoV0A16_installation_idSp...Sgvg`; `ImportedStructMemberMatching`'s own
/// simple parser reads the `"0"` right after the struct's own `"V"` marker as a zero-length
/// identifier and correctly bails (rather than guess) instead of recognizing it as the start of a
/// real compound-identifier encoding.
///
/// Rather than hand-derive Swift's own real compound-identifier mangling grammar here (real risk of
/// a subtly wrong parse), this defers to the real demangler (`swift-demangle`, via
/// `DemangledSiblingMatching`) and checks the *demangled* text's own shape instead. Confirmed via a
/// real, controlled comparison: a raw struct field demangles to
/// `__C.<TypeName>.<memberName>.getter/setter : <ReturnType>` (`CGSize.width` ->
/// `"__C.CGSize.width.getter : Swift.Double"`), while a genuine Swift-authored *extension* member on
/// the same imported type is always prefixed `"(extension in <Module>):"` by `swift-demangle` itself
/// (`CGSize.isEmpty` -> `"(extension in CoreGraphics):__C.CGSize.isEmpty.getter : Swift.Bool"`) --
/// real, reliable discriminator, not guessed.
///
/// **Still requires the mangled USR's own container-kind marker to be `"V"` (struct), never `"C"`
/// (class)** -- reusing `ImportedStructMemberMatching`'s own already-proven type-name-plus-marker
/// parse for that part, since a raw C **class** member can genuinely carry a real isolation attribute
/// (`BridgedExternClassConstantMatching`'s own confirmed `UITableView.automaticDimension` case,
/// which is *also* `__C.`-prefixed with no `"(extension in "` -- so `"__C."` alone is not a safe
/// discriminator on its own, only combined with the struct-only mangling check). Every real
/// Objective-C/C **struct**, unlike a class, is categorically outside Swift's actor-isolation
/// attribute system for its own original declaration -- there is no possible world where a raw C
/// struct field carries `@MainActor` -- so once both checks pass, this is unconditionally
/// `.nonisolated`, no live query needed.
public enum DemangledStructMemberMatching {
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

    /// `true` only for a targetUSR shaped like `"s:So<N><TypeName>V..."` (a raw imported struct,
    /// confirmed via the same type-name-plus-`"V"`-marker parse `ImportedStructMemberMatching` uses)
    /// whose remaining, not-otherwise-parsed member portion is non-empty -- i.e. "this is worth
    /// demangling to check," never a claim about isolation on its own. Real member-name validation
    /// happens in `isUnconditionallyNonisolated(rawDemangled:)` against the demangled text.
    public static func isCandidateRawStructMember(targetUSR: String) -> Bool {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return false }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard readLengthPrefixedIdentifier(&remainder) != nil else { return false }
        guard remainder.hasPrefix("V") else { return false }
        remainder = remainder.dropFirst(1)
        return !remainder.isEmpty
    }

    /// `rawDemangled` is `DemangledSiblingMatching.rawDemangled(forSwiftUSRs:processRunning:)`'s own
    /// **unstripped** output for `targetUSR` -- must be the raw form, not `moduleAgnosticSignatures`'s
    /// module-stripped one, since stripping the leading component would destroy the exact `"__C."`
    /// vs. `"(extension in "` distinction this depends on. `isCandidateRawStructMember` must be
    /// checked first; this only validates the *shape* of the demangled text.
    public static func isUnconditionallyNonisolated(rawDemangled: String) -> Bool {
        rawDemangled.hasPrefix("__C.") && (rawDemangled.contains(".getter : ") || rawDemangled.contains(".setter : "))
    }
}
