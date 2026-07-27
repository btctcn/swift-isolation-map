class SyncCoordinator {
    // A stored property, deliberately unrelated to the class's own cross-file-witness purpose --
    // exists solely so DeclarationLinkerTests.swift can verify, against a real synthesized
    // getter/setter USR, which side of IndexStoreDB's `.accessorOf` relation carries the mapping
    // back to the property's own canonical USR (Gap A, docs/task-compiled-dependency-isolation-
    // usr-granularity.md).
    var counter: Int = 0

    func unrelatedMethod() {}
}
