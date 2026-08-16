import Foundation

/// Fallback matching for a real, confirmed gap `BulkSymbolGraphExtractor`'s bulk cache can never
/// resolve by construction: a plain, non-member Objective-C/C `extern const` global imported
/// directly into Swift's module namespace (`NSCocoaErrorDomain`, `kNumberCaseType`, ...) mangles
/// with **no nominal-type context at all** -- unlike `ImportedStructMemberMatching`'s raw struct
/// field or `BridgedExternClassConstantMatching`'s class-exposed constant, there is no containing
/// type USR to key a bulk-cache dictionary by in the first place; the bulk cache is keyed by the
/// symbol's own real Clang USR (`c:@NSCocoaErrorDomain`), never the Swift-mangled one the call
/// graph's own `calleeUSR` carries.
///
/// **Checked, not assumed** (this project's own "no unproven claims" discipline, directly
/// reinforced after `BridgedExternClassConstantMatching`'s own sibling case turned out to
/// genuinely carry `@MainActor` despite an initial by-analogy guess otherwise): a real
/// live-toolchain probe against both `NSCocoaErrorDomain` and CoreText's `kNumberCaseType`
/// confirmed their real `declarationFragments` carry **no attribute of any kind** -- plain
/// `let NSCocoaErrorDomain: String` / `var kNumberCaseType: Int { get }`. A plain top-level Clang
/// global constant, unlike a class's own static/instance member, is never a point Apple's headers
/// attach `NS_SWIFT_UI_ACTOR`/`@MainActor` to -- there is no "actor" for a bare global value to be
/// affiliated with in the first place, structurally distinct from the class-member case.
///
/// **Real USR mangling grammar**, confirmed against dozens of real, independent examples across
/// several unrelated modules (`Foundation`, `CoreText`, `CoreTelephony`, `Contacts`) on a real
/// corpus -- `NSCocoaErrorDomain`, `NSPersistentStoreForceDestroyOption`, `kNumberCaseType`,
/// `CTRadioAccessTechnologyLTE`, `CNContactPhoneNumbersKey`, `NSURLSessionTransferSizeUnknown`,
/// and more:
/// ```
/// s:So<N><Name><ReturnTypeMangling>vg   // read-only or var getter
/// s:So<N><Name><ReturnTypeMangling>vs   // var setter
/// ```
///
/// **`"SC"` variant, same grammar, a real distinct module code**: Swift's mangling assigns a
/// separate synthetic-module substitution code to a **plain C** (non-Objective-C) macro constant --
/// `"SC"`, not `"So"` -- real examples found on `Project Iris` across `SQLite3`
/// (`SQLITE_ROW`/`SQLITE_OK`/`SQLITE_OPEN_READONLY`/`SQLITE_OPEN_FULLMUTEX`), `Darwin`
/// (`NSEC_PER_SEC`/`USEC_PER_SEC`/`AF_INET`), `CommonCrypto` (`CC_SHA256_DIGEST_LENGTH`), and
/// `CoreFoundation` (`kCFStringEncodingInvalidId`). Checked, not assumed by analogy: a real
/// `swift symbolgraph-extract -module-name Darwin` run confirms `NSEC_PER_SEC`/`USEC_PER_SEC`/
/// `AF_INET`'s own `declarationFragments` carry no isolation attribute of any kind either -- their
/// real Clang USR is even further from having one (`c:@macro@NSEC_PER_SEC`, a preprocessor macro,
/// not even a real Clang declaration) -- so the exact same "no actor to be affiliated with"
/// reasoning applies at least as strongly as it does for the `"So"` case.
/// Deliberately never parses `<ReturnTypeMangling>` -- like `ImportedStructMemberMatching`, only
/// the exact `"vg"`/`"vs"` accessor-kind suffix at the very end is checked, since the real type
/// varies freely (`String`, `Int`, `Int64`, ...).
///
/// **The critical discriminator against every member-shaped sibling** (`ImportedStructMemberMatching`,
/// `BridgedExternClassConstantMatching`, `BridgedExternConstantMatching`): real Swift mangling is
/// unambiguous by construction -- a nominal-type member's context always inserts a nominal-kind
/// marker character (`V`/`C`/`O`/`a`/`P`) *immediately* after the container type's own
/// length-prefixed name, before the member's own length-prefixed name. A plain top-level global has
/// no such context at all, so the character immediately following its own length-prefixed name is
/// never one of those markers (it's either the start of a Swift-stdlib 2-character substitution
/// like `"SS"`/`"Si"`, or a digit starting the return type's *own* length-prefixed module name --
/// never a bare marker letter in that exact position). Checking for the *absence* of a marker
/// immediately after the first identifier -- not merely "ends in vg/vs" alone, which every member
/// accessor also does -- is what keeps this from misfiring on a real class's own unattributed
/// instance property (confirmed against a real false-positive risk found during this fix's own
/// design: `UISceneConnectionOptions.shortcutItem`, mangled
/// `s:So24UISceneConnectionOptionsC12shortcutItemSo021UIApplicationShortcutE0CSgvg` -- ends in
/// `"vg"` exactly like a real top-level constant would, but the `"C"` immediately after
/// `"UISceneConnectionOptions"` correctly identifies it as a class member, not a bare global,
/// and this type's own `isTopLevelImportedConstant` correctly returns `false` for it).
public enum ImportedTopLevelConstantMatching {
    private static let nominalMarkers: Set<Character> = ["V", "C", "O", "a", "P"]

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

    /// `true` when `targetUSR` is shaped like a plain, non-member imported Clang global constant
    /// per this type's own doc comment grammar -- `false` for every member-shaped sibling case and
    /// every USR not shaped this way at all (the overwhelmingly common case).
    public static func isTopLevelImportedConstant(usr targetUSR: String) -> Bool {
        let objcModulePrefix = "s:So"
        let plainCModulePrefix = "s:SC"
        let prefix: String
        if targetUSR.hasPrefix(objcModulePrefix) {
            prefix = objcModulePrefix
        } else if targetUSR.hasPrefix(plainCModulePrefix) {
            prefix = plainCModulePrefix
        } else {
            return false
        }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard readLengthPrefixedIdentifier(&remainder) != nil else { return false }
        guard let firstCharacterAfterName = remainder.first, !nominalMarkers.contains(firstCharacterAfterName) else {
            return false
        }
        return remainder.hasSuffix("vg") || remainder.hasSuffix("vs")
    }
}
