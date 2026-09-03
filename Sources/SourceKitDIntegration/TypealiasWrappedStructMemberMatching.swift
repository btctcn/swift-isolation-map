import Foundation

/// A ninth, real gap (issue #127): `MKCoordinateRegion.center`'s setter (real corpus,
/// `coordinateRegion?.center = center`) carries a Swift-mangled property-accessor USR shaped
/// exactly like `DemangledStructMemberMatching`'s own `"V"`-marked raw-struct-field case
/// (`s:So<N><TypeName><marker><N2><MemberName><ReturnTypeMangling>v[g|s]`), but with marker `"a"`
/// (typealias) instead of `"V"` (struct). Confirmed via a real `symbolgraph-extract -module-name
/// MapKit` dump: `MKCoordinateRegion`'s own declaration genuinely is `kind.identifier:
/// "swift.struct"`, `identifier.precise: c:@SA@MKCoordinateRegion` -- but ClangImporter still
/// mangles every reference to it with the typealias marker, because the real underlying C
/// declaration is an *anonymous* struct given a name only via `typedef struct { ... }
/// MKCoordinateRegion;` (`"@SA@"`, not the tag-named-struct form `"@S@"` a `struct Foo { ... }
/// MKCoordinateRegion;` would use -- both are genuinely struct forms, `DemangledStructMemberMatching`'s
/// own sibling `ImportedStructMemberMatching` already treats `"@S@"` as struct-only for exactly this
/// reason).
///
/// **Why `DemangledStructMemberMatching`'s own `"V"`-only bulk-cache gate can't just be widened to
/// accept `"a"` too**: `"a"` is genuinely ambiguous on its own -- it's also the exact marker
/// `BridgedExternConstantMatching`'s own confirmed `NSAttributedString.Key.font` case uses, wrapping
/// a type that traces back to a real Objective-C *class* lineage (`NSString`). Blindly trusting any
/// `"a"`-marked container as unconditionally `.nonisolated` (that bulk path's whole reason for
/// existing -- zero live query at all) would risk exactly the false positive this project's
/// discipline exists to avoid.
///
/// **Why the *live-query* path doesn't have that risk, and needs no struct/class disambiguation of
/// its own**: a live `cursorinfo` query fully resolves *effective* isolation, including inherited
/// isolation from a container's own class hierarchy (`SymbolGraphIsolationParser`'s own doc comment:
/// a live query's `declarationFragments` genuinely restate `@MainActor` for `UINavigationController
/// .pushViewController` even though nothing on that one method's own declaration says so -- unlike a
/// whole-module bulk dump, which never restates inherited isolation per member). So once the *right*
/// live-query candidate is selected, the existing, already-correct `SymbolGraphIsolationParser
/// .isolation(fromSymbolGraphJSON:)` safely reports `.nonisolated` for a genuinely unisolated member
/// regardless of whether its container turns out to be a struct or a class -- the missing piece was
/// only ever *candidate selection*: a real live probe at the real call site (`MapViewController.swift`,
/// the original edge's own location) returns the correct declaration
/// (`c:@SA@MKCoordinateRegion@FI@center`, no isolation attribute at all in its own
/// `declarationFragments`) under a Clang-form USR `USRMatching`'s strict equality against the
/// Swift-mangled `targetUSR` can never match.
///
/// **Real USR mangling grammar**, confirmed via both the original real corpus edge and a
/// from-scratch minimal reproduction (a plain property read/write against a real
/// `Optional<MKCoordinateRegion>`, compiled to a real local index store):
/// ```
/// targetUSR:        s:So<N><TypeName>a<N2><MemberName><ReturnTypeMangling>v[g|s]
/// containerTypeUSR: $sSo<N><TypeName>aD
/// ```
/// mirrors `ObjCProtocolPropertyWitnessMatching`'s own `"D"`-suffixed instance-member
/// container-type-USR shape exactly, just with the nominal marker `"a"` instead of `"C"`. Like that
/// type, this deliberately never compares the candidate's own member name (the query already runs
/// at the exact position the original call-graph edge itself recorded) -- only that the candidate
/// is genuinely Clang-presented, a plain imported-struct field (`"c:@S@"`/`"c:@SA@"` USR prefix --
/// **never** `"c:objc(cs)"`, the one shape a genuine Objective-C class always uses instead,
/// confirmed via `BridgedExternClassConstantMatching`'s own real class-marker precedent; a cheap
/// extra confirmation this is really matching a struct field rather than trusting the
/// container-type-USR string coincidence alone -- not load-bearing for isolation *correctness*,
/// which the live-query-resolves-inheritance argument above already covers regardless of container
/// kind), and from the same container `targetUSR` itself names.
public enum TypealiasWrappedStructMemberMatching {
    public struct ParsedTarget: Equatable {
        public let typeName: String
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

    /// Parses `targetUSR` per this type's own doc comment grammar. Requires the real property-
    /// accessor suffix `"vg"`/`"vs"` specifically -- distinct from (never overlapping with)
    /// `SubscriptAccessorDeclarationMatching`'s own `"cig"`/`"cis"` subscript-accessor domain, since
    /// the two-character endings differ (`"ig"`/`"is"` vs. `"vg"`/`"vs"`).
    public static func parse(targetUSR: String) -> ParsedTarget? {
        let prefix = "s:So"
        guard targetUSR.hasPrefix(prefix) else { return nil }
        var remainder = targetUSR.dropFirst(prefix.count)
        guard let typeName = readLengthPrefixedIdentifier(&remainder) else { return nil }
        guard remainder.hasPrefix("a") else { return nil }
        remainder = remainder.dropFirst(1)
        guard remainder.hasSuffix("vg") || remainder.hasSuffix("vs") else { return nil }
        return ParsedTarget(typeName: typeName)
    }

    /// The reconstructed `key.containertypeusr` a genuine same-container candidate must carry --
    /// confirmed exactly against the real probe: `"$sSo18MKCoordinateRegionaD"`.
    public static func expectedContainerTypeUSR(forTypeName typeName: String) -> String {
        "$sSo\(typeName.utf8.count)\(typeName)aD"
    }

    public static func matches(candidate: CursorInfoSymbol, target: ParsedTarget) -> Bool {
        candidate.declLang == "source.lang.objc"
            && (candidate.usr.hasPrefix("c:@S@") || candidate.usr.hasPrefix("c:@SA@"))
            && candidate.containerTypeUSR == expectedContainerTypeUSR(forTypeName: target.typeName)
    }

    /// Entry point mirroring `ObjCProtocolPropertyWitnessMatching.select(from:targetUSR:)`'s own
    /// shape -- intended to run only after `USRMatching.select` and every earlier fallback in the
    /// same `??` chain have already returned `nil`.
    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        guard let target = parse(targetUSR: targetUSR) else { return nil }
        return result.all.first { matches(candidate: $0, target: target) }
    }
}
