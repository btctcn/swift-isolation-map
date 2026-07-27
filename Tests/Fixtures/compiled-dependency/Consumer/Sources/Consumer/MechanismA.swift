import AppKit

/// Mechanism A: a real, Apple-shipped, ObjC-bridged `@MainActor` type (`NSCell`, whose own
/// `NS_SWIFT_UI_ACTOR` header macro was confirmed directly against the real SDK header during the
/// research spike -- `docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`). No synthetic
/// dependency needed: this is exactly the shape (`UITableViewCell`, `NewsTableCell`) the original
/// motivating bug was.
final class ProjectCell: NSCell {
    func touch() {
        title = "x"
    }
}

nonisolated func callMechanismA() async {
    let cell = await ProjectCell()
    await cell.touch()
}
