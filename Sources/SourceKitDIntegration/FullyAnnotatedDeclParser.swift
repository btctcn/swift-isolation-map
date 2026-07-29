import Foundation
import IsolationCore

/// Fallback isolation parser over `key.fully_annotated_decl` XML -- used only when
/// `SymbolGraphIsolationParser` yields `nil` (a real symbol-graph parse failure) but this field is
/// non-empty. Real shapes confirmed empirically (research spike's raw `sourcekitd` dlopen check,
/// `DivergentIsolation` fixture): a global-actor attribute nests a `<ref.class usr="...">Name</ref.class>`
/// inside `<syntaxtype.attribute.name>` (e.g. `@<ref.class usr="s:ScM">MainActor</ref.class>`);
/// `nonisolated` appears as plain text directly inside the same tag, no nested element
/// (`<syntaxtype.attribute.name>nonisolated</syntaxtype.attribute.name>`).
public enum FullyAnnotatedDeclParser {
    /// Same return-value contract as `SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON:)`:
    /// `nil` only for a genuine XML parse failure (caller treats that as `unknown`); a
    /// successfully parsed declaration with no isolation attribute at all returns `.nonisolated`,
    /// a real, positive fact -- not `nil`.
    public static func isolation(fromXML xml: String) -> IsolationKind? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = IsolationXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result ?? .nonisolated
    }
}

private final class IsolationXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var result: IsolationKind?
    private var insideAttributeName = false
    private var pendingActorName: String?
    private var pendingActorUSR: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "syntaxtype.attribute.name" {
            insideAttributeName = true
        }
        if insideAttributeName, elementName.hasPrefix("ref."), let usr = attributeDict["usr"] {
            pendingActorName = ""
            pendingActorUSR = usr
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideAttributeName, result == nil else { return }
        if pendingActorName != nil {
            pendingActorName! += string
            return
        }
        if string.trimmingCharacters(in: .whitespacesAndNewlines) == "nonisolated" {
            result = .nonisolated
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        // See `GlobalActorNameValidation`'s own doc comment: a resolvable `usr` alone (any
        // `ref.*` element) is not sufficient evidence this is a global actor -- e.g. a
        // `@StateObject`-attributed property's `ref.struct` resolves just as cleanly.
        if elementName.hasPrefix("ref."), let name = pendingActorName, result == nil,
           GlobalActorNameValidation.isGlobalActorName(spelling: name, usr: pendingActorUSR) {
            result = .globalActor(name: name)
        }
        if elementName.hasPrefix("ref.") {
            pendingActorName = nil
            pendingActorUSR = nil
        }
        if elementName == "syntaxtype.attribute.name" {
            insideAttributeName = false
        }
    }
}
