import ExternalDepCore

/// Negative control: `PlainNonisolated` is genuinely, unambiguously nonisolated -- no attribute
/// anywhere in its chain. Must never be misreported as isolated (a false positive would be the
/// exact opposite failure mode from the one this whole task exists to fix, but a real one to
/// guard against).
func callNegativeControl() {
    let value = PlainNonisolated()
    value.touch()
}
