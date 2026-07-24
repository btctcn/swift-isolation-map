/// Standard iterative Levenshtein edit distance (single-row DP, O(min(a,b)) memory).
func levenshteinDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }

    var previousRow = Array(0...b.count)
    var currentRow = [Int](repeating: 0, count: b.count + 1)

    for i in 1...a.count {
        currentRow[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            currentRow[j] = Swift.min(
                previousRow[j] + 1,        // deletion
                currentRow[j - 1] + 1,     // insertion
                previousRow[j - 1] + cost  // substitution
            )
        }
        previousRow = currentRow
    }
    return previousRow[b.count]
}

/// Architecture spec section 3: "on a name mismatch, show the list of available schemes/products/
/// targets with a fuzzy 'did you mean' suggestion (Levenshtein-based)." Returns the closest name
/// only when it's plausibly a typo (distance no more than a third of the requested name's length,
/// with a floor of 1) -- otherwise `nil`, since a wildly different name isn't a helpful suggestion.
public func closestSchemeName(to requested: String, among available: [String]) -> String? {
    guard let closest = available.min(by: { levenshteinDistance(requested, $0) < levenshteinDistance(requested, $1) }) else {
        return nil
    }
    let distance = levenshteinDistance(requested, closest)
    let threshold = max(1, requested.count / 3)
    return distance <= threshold ? closest : nil
}

/// The full user-facing message for a scheme/target name mismatch: the "did you mean" suggestion
/// when plausible, plus the full list of available names either way.
public func schemeMismatchMessage(requested: String, available: [String]) -> String {
    var lines: [String] = []
    if let suggestion = closestSchemeName(to: requested, among: available) {
        lines.append("No scheme, product, or target named '\(requested)'. Did you mean '\(suggestion)'?")
    } else {
        lines.append("No scheme, product, or target named '\(requested)'.")
    }
    if available.isEmpty {
        lines.append("No schemes, products, or targets were found.")
    } else {
        lines.append("Available: \(available.sorted().joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
}
