nonisolated func trigger() async {
    let coordinator = SyncCoordinator()
    coordinator.unrelatedMethod()
    await coordinator.refresh()
}

await trigger()
