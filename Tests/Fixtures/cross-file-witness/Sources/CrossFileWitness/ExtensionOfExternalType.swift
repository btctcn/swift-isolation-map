import AppKit

// Extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md): `NSView`
// is a real, unambiguous `@MainActor` AppKit type (confirmed empirically elsewhere this session,
// `BulkSymbolGraphExtractorTests.swift`'s "Live toolchain: bulk-extracting real AppKit... resolves
// NSView to @MainActor"). `realExtensionMethod` has no isolation of its own; its only source of
// isolation is `NSView` itself, which has no primary declaration in this project -- exactly the
// motivating shape (`UIViewController` in the real `~/ios` case).
extension NSView {
    func realExtensionMethod() {}
}

// V4: an extension of a *nested* type -- the extended type itself is nested, not the extension's
// own enclosing context. Project-local (not external), but exercises the same `.childOf`/
// `.extendedBy` chain on a shape a location- or name-based scheme would fray on.
struct NestedContainer {
    struct Inner {}
}

extension NestedContainer.Inner {
    func nestedExtensionMethod() {}
}

// V4: an extension of a generic type.
struct GenericContainer<Element> {}

extension GenericContainer {
    func genericExtensionMethod() {}
}
