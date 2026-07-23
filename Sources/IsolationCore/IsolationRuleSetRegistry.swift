/// Maps a detected Swift language version to the rule set that governs it. Deliberately
/// throws rather than falling back to the nearest known rule set: per the architecture spec
/// (section 2.8), a project on an unreviewed Swift version must produce an explicit warning,
/// not a silent, possibly-wrong result.
public enum IsolationRuleSetRegistry {
    public static func ruleSet(
        forSwiftVersion version: String,
        defaultIsolation: IsolationKind = .nonisolated
    ) throws -> IsolationRuleSet {
        let candidates: [IsolationRuleSet] = [
            Swift5RuleSet(),
            Swift60RuleSet(),
            Swift61RuleSet(),
            Swift62RuleSet(defaultIsolation: defaultIsolation),
            Swift63RuleSet(defaultIsolation: defaultIsolation)
        ]
        guard let match = candidates.first(where: { $0.swiftVersion.contains(version) }) else {
            throw UnsupportedSwiftVersionError(version: version, highestSupportedUpperBound: candidates.compactMap(\.swiftVersion.upperBound).last)
        }
        return match
    }
}

public struct UnsupportedSwiftVersionError: Error, Equatable {
    public let version: String
    public let highestSupportedUpperBound: String?
}
