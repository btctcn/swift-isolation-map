// Cross-file type-entry collision fix (docs/task-cross-file-type-entry-collision.md): a type with
// its primary declaration (superclass + one conformance) here, and a *second* conformance stated
// only in a separate extension file (MultiFileTypeExtension.swift) -- mirrors the real
// `~/ios` case (`AppDelegate: MindboxAppDelegate` in AppDelegate.swift, `extension AppDelegate` in
// a separate test file) that exposed this bug.
protocol MultiFileFirstProtocol {}
class MultiFileBase {}
class MultiFileType: MultiFileBase, MultiFileFirstProtocol {}
