// Exists solely so DeclarationLinkerTests.swift's baseTypeUSRs direction test can also confirm
// the *direct* inheritance shape (declared on the primary declaration itself, not via a separate
// extension) -- Gap B, docs/task-gap-b-implementation-plan.md's Phase I2.
class BaseWidget {}

class DerivedWidget: BaseWidget {}
