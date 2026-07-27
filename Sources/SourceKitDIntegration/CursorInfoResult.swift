import Foundation

/// One `sourcekitd` cursor-info result -- either the top-level primary result or one element of
/// `key.secondary_symbols` (confirmed by the research spike's dlopen check: a constructor call
/// like `Type()` returns the type as primary and the specific `init()` as secondary, each fully
/// independent, each carrying its own USR/annotated-declaration/symbol-graph).
public struct CursorInfoSymbol: Equatable, Sendable {
    public let usr: String
    public let fullyAnnotatedDeclXML: String?
    public let symbolGraphJSON: String?

    public init(usr: String, fullyAnnotatedDeclXML: String?, symbolGraphJSON: String?) {
        self.usr = usr
        self.fullyAnnotatedDeclXML = fullyAnnotatedDeclXML
        self.symbolGraphJSON = symbolGraphJSON
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
