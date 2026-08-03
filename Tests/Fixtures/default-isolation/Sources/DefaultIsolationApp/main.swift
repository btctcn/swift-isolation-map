// SE-0466: with `-default-isolation MainActor` configured (this fixture's own Package.swift),
// an otherwise-unattributed, uninherited declaration defaults to @MainActor -- the real,
// end-to-end regression case for docs/task-default-isolation-detection.md (issue #30):
// swift-isolation-map must read this real, configured value from the project's own build
// arguments, not assume `.nonisolated`.
class Widget {
    func render() {}
}

nonisolated class ExplicitlyOptedOut {
    func doWork() {}
}

Widget().render()
ExplicitlyOptedOut().doWork()
