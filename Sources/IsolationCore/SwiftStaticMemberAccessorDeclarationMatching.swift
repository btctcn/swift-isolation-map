import Foundation

/// A pure-Swift sibling to `SubscriptAccessorDeclarationMatching`'s own "accessor USR vs.
/// declaration USR" gap, for a *static var* rather than a subscript: the call graph's own
/// `calleeUSR` for `SomeType.staticMember` is the accessor form (`"...vgZ"`/`"...vsZ"`), but the
/// bulk symbol graph's own `identifier.precise` -- and any live hover -- key it by the
/// **declaration** form (`"...vpZ"`) instead. Confirmed real on Project Iris: a real
/// `swift symbolgraph-extract` run against `YandexPaySDK`'s own built framework
/// (`YandexPaySDKApi.instance`/`.isInitialized`, a plain pure-Swift singleton, no isolation
/// attribute of any kind in its own `declarationFragments`) shows its declaration's own precise USR
/// as `s:12YandexPaySDK0aB6SDKApiC8instanceACvpZ`, never the `"...vgZ"` accessor form the call
/// graph carries.
///
/// **Deliberately requires a real, digit-length-prefixed module name immediately after `"s:"`** --
/// excludes `"s:So..."` (Clang-imported/ObjC-bridged) on purpose. `BridgedExternClassConstantMatching`
/// already handles that shape, specifically via a *live* query, never zero-query, because its own
/// real isolation can come from class-level inheritance that a bulk symbol-graph extraction doesn't
/// restate per-member (`docs/task-bulk-symbolgraph-inherited-isolation.md`'s own confirmed gap) --
/// this type must never compete with or shadow that more careful, already-correct path.
public enum SwiftStaticMemberAccessorDeclarationMatching {
    public static func declarationUSR(forStaticAccessorUSR targetUSR: String) -> String? {
        guard MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: targetUSR) != nil else { return nil }
        guard targetUSR.hasSuffix("vgZ") || targetUSR.hasSuffix("vsZ") else { return nil }
        var characters = Array(targetUSR)
        characters[characters.count - 2] = "p"
        return String(characters)
    }
}
