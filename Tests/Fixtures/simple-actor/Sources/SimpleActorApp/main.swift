actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }
}

nonisolated func trigger(_ counter: Counter) async {
    await counter.increment()
}

await trigger(Counter())
