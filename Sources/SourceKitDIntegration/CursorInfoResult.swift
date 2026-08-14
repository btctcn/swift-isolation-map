import Foundation

/// One `sourcekitd` cursor-info result -- either the top-level primary result or one element of
/// `key.secondary_symbols` (confirmed by the research spike's dlopen check: a constructor call
/// like `Type()` returns the type as primary and the specific `init()` as secondary, each fully
/// independent, each carrying its own USR/annotated-declaration/symbol-graph).
public struct CursorInfoSymbol: Equatable, Sendable {
    public let usr: String
    public let fullyAnnotatedDeclXML: String?
    public let symbolGraphJSON: String?
    /// `key.name` -- the declaration's own bare name (e.g. `"font"`), independent of USR. Needed by
    /// `BridgedExternConstantMatching` (docs/task-extern-constant-swift-name-usr-mismatch.md §15) to
    /// recognize a Clang-side candidate as the same declaration a Swift-mangled `targetUSR` names,
    /// when strict USR equality (`USRMatching`) can never hold for this shape by construction.
    public let name: String?
    /// `key.decl_lang` (`source.lang.swift`/`source.lang.objc`/...), read as its real UID string --
    /// see `name`'s own doc comment for why this project needs it now.
    public let declLang: String?
    /// `key.containertypeusr` -- the Swift-mangled USR of the type this declaration is a member of.
    /// See `name`'s own doc comment for why this project needs it now.
    public let containerTypeUSR: String?

    public init(
        usr: String, fullyAnnotatedDeclXML: String?, symbolGraphJSON: String?,
        name: String? = nil, declLang: String? = nil, containerTypeUSR: String? = nil
    ) {
        self.usr = usr
        self.fullyAnnotatedDeclXML = fullyAnnotatedDeclXML
        self.symbolGraphJSON = symbolGraphJSON
        self.name = name
        self.declLang = declLang
        self.containerTypeUSR = containerTypeUSR
    }
}

public struct CursorInfoResult: Equatable, Sendable {
    public let primary: CursorInfoSymbol
    public let secondary: [CursorInfoSymbol]

    public init(primary: CursorInfoSymbol, secondary: [CursorInfoSymbol]) {
        self.primary = primary
        self.secondary = secondary
    }

    /// Every candidate result at the queried position -- the set `USRMatching.select` searches,
    /// never scanned for text/substrings per the binding design (result selection is strictly by
    /// USR equality).
    public var all: [CursorInfoSymbol] { [primary] + secondary }
}
