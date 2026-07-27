import Foundation

/// Module-default-isolation shape (SE-0466/478): no attribute anywhere, no isolated ancestor --
/// isolation exists purely because this module was compiled with `-default-isolation MainActor`.
/// Compiled as its own target specifically so that build flag doesn't also apply to
/// `ExternalDepCore`'s types, which must stay genuinely, ordinarily nonisolated by default.
open class ModuleDefaultIsolated {
    public init() {}
    open func touch() {}
}
