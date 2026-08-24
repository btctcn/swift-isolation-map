import Foundation

/// A real, out-of-tree compiled dependency's own custom global actor -- Issue #40's exact shape:
/// this type's source is never parsed by swift-isolation-map (only its compiled .swiftmodule is
/// linked against), so it can never enter `FileWideNames.globalActorNames`'s project-wide
/// accept-list by construction.
@globalActor
public actor ThirdPartyActor {
    public static let shared = ThirdPartyActor()
}

/// A real API isolated to that third-party actor -- the callee side of the gap.
@ThirdPartyActor
public func thirdPartyIsolatedWork() {}
