import Foundation
import IsolationCore

/// Parses a `key.symbol_graph` document's declaration fragments -- the primary, structured format
/// per the binding design (`"kind": "attribute"` JSON fragments, global-actor name via
/// `preciseIdentifier`, never text/substring scanning).
///
/// Return-value contract, important and easy to get backwards: `nil` means the JSON itself could
/// not be parsed (a real format failure -- the caller must treat this as `unknown`, per the
/// binding design). A **matched, successfully-parsed** result with **no attribute fragment at
/// all** is not a failure -- it is the compiler's genuine, positive signal that this declaration
/// has no isolation of its own (`ActorIsolation::Unspecified` never gets an attribute attached at
/// all, confirmed directly in `swiftlang/swift`'s `TypeCheckConcurrency.cpp`,
/// `addAttributesForActorIsolation`, and empirically via the research spike's own negative
/// control) -- that case returns `.nonisolated`, a real fact, not `nil`.
public enum SymbolGraphIsolationParser {
    public static func isolation(fromSymbolGraphJSON json: String) -> IsolationKind? {
        guard let data = json.data(using: .utf8),
              let document = try? JSONDecoder().decode(SymbolGraphDocument.self, from: data),
              let symbol = document.symbols.first else {
            return nil
        }
        return isolation(fromFragments: symbol.declarationFragments ?? [])
    }

    static func isolation(fromFragments fragments: [SymbolGraphDocument.Symbol.Fragment]) -> IsolationKind {
        for fragment in fragments where fragment.kind == "attribute" {
            if fragment.spelling == "nonisolated" {
                return .nonisolated
            }
            // The bare "@" punctuation fragment has no `preciseIdentifier`; the actor-name
            // fragment that follows it does (e.g. `s:ScM` for `MainActor`) -- necessary, but not
            // sufficient, evidence this fragment names a real global actor: a resolvable USR only
            // means the fragment references *some* real type, not that the type is a global actor
            // (see `GlobalActorNameValidation`'s own doc comment -- `@StateObject` resolves just as
            // cleanly and is not an actor at all).
            if let usr = fragment.preciseIdentifier, GlobalActorNameValidation.isGlobalActorName(spelling: fragment.spelling, usr: usr) {
                return .globalActor(name: fragment.spelling)
            }
        }
        return .nonisolated
    }
}

struct SymbolGraphDocument: Decodable {
    let symbols: [Symbol]

    struct Symbol: Decodable {
        let declarationFragments: [Fragment]?

        struct Fragment: Decodable {
            let kind: String
            let spelling: String
            let preciseIdentifier: String?
        }
    }
}
