import Foundation

/// `Hashable`'s `hashValue` requirement has a default implementation in the standard library's own
/// protocol extension (computed from `hash(into:)`) -- a conforming type never gets its own
/// `SwiftSyntax` node for this accessor (no source token exists for it, even when the type provides
/// a custom `hash(into:)`/`==`), so `DeclarationExtractor` never sees it and `DeclarationLinker`
/// never links it, exactly like `SynthesizedEnumAccessorMatching`'s `rawValue`/`allCases` case.
///
/// Real corpus evidence (Project Iris): `Moya.Endpoint`, `Mindbox.ApplicationEvent`,
/// `Mindbox.InAppMessageTriggerEvent` -- all real, project-local-to-the-analysis Pod source, already
/// linked with a real location via ordinary `DeclarationExtractor`/`DeclarationLinker` extraction --
/// each contribute an unresolved `<TypeUSR>9hashValueSivg` call-graph edge with no declaration of
/// its own.
///
/// **Unlike `SynthesizedEnumAccessorMatching`'s `rawValue`/`allCases`** (unconditionally
/// `.nonisolated` by real, independently-confirmed Swift semantics), `hashValue`'s own isolation is
/// *not* assumed here -- whether a default-witness protocol-extension method genuinely inherits the
/// conforming type's own actor isolation is a real, non-obvious question this fix does not need to
/// answer, because it doesn't have to: attaching the type's own `containingTypeUSR` to a synthesized
/// `DeclarationInfo` (no `explicitIsolation`) and letting the existing, unmodified
/// `IsolationInferenceEngine` apply its own already-verified whole-type inference rule to it --
/// exactly as it already does for every real member of that same type -- answers the question
/// correctly without touching or re-deriving that logic here.
///
/// **Grammar**: the accessor USR is always the enclosing type's own real USR with the literal
/// `"9hashValueSivg"` suffix appended directly -- confirmed against all three real corpus examples
/// above (`s:4Moya8EndpointC9hashValueSivg` -> `s:4Moya8EndpointC`,
/// `s:7Mindbox24InAppMessageTriggerEventO9hashValueSivg` -> `s:7Mindbox24InAppMessageTriggerEventO`),
/// spanning both a class and an enum container marker. `hashValue` is always an instance property
/// (`Hashable` has no static requirement of this name), so there is no `"...vgZ"` static variant to
/// account for, unlike `SynthesizedEnumAccessorMatching`'s `allCases`.
public enum SynthesizedHashableAccessorMatching {
    private static let accessorSuffix = "9hashValueSivg"

    public static func enclosingTypeUSR(forSynthesizedAccessorUSR targetUSR: String) -> String? {
        let prefix = "s:"
        guard targetUSR.hasPrefix(prefix), targetUSR.hasSuffix(accessorSuffix),
              targetUSR.count > prefix.count + accessorSuffix.count else {
            return nil
        }
        return String(targetUSR.dropLast(accessorSuffix.count))
    }
}
