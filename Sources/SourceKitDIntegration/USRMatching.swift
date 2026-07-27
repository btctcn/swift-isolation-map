import Foundation

/// Strict USR-equality result selection -- the binding design's non-negotiable requirement
/// (docs/compiled-dependency-isolation-sourcekit-lsp-spike.md's "Second addendum"/"Fourth
/// addendum"): a cursor-info response is a *set* of candidate results (primary + secondary), and
/// only USR equality picks the one matching a real call-graph edge's known member USR --
/// text/substring scanning for `@MainActor` is exactly the confident-wrong-answer failure mode
/// this whole task exists to eliminate.
public enum USRMatching {
    /// Symbols presented through a synthesized extension carry a suffixed USR
    /// (`<baseUSR>::SYNTHESIZED::<extendedNominalUSR>`, confirmed against real `sourcekitd`
    /// source, `SwiftLangSupport.SynthesizedUSRSeparator`) -- match the exact USR first, else the
    /// prefix before this separator, so such members aren't silently misreported as unresolved.
    static let synthesizedUSRSeparator = "::SYNTHESIZED::"

    public static func matches(candidateUSR: String, targetUSR: String) -> Bool {
        if candidateUSR == targetUSR {
            return true
        }
        if let range = candidateUSR.range(of: synthesizedUSRSeparator) {
            return String(candidateUSR[..<range.lowerBound]) == targetUSR
        }
        return false
    }

    public static func select(from result: CursorInfoResult, targetUSR: String) -> CursorInfoSymbol? {
        result.all.first { matches(candidateUSR: $0.usr, targetUSR: targetUSR) }
    }
}
