import Foundation

extension Bridges {
    /// Runs `body` for every file on all cores and concatenates the results
    /// in file-name order, so output never depends on scheduling.
    static func perFile<T: Sendable>(_ texts: [String: String], where keep: (String) -> Bool = { _ in true },
                                     _ body: @Sendable (String, String) -> [T]) -> [T] {
        let items = texts.filter { keep($0.key) }.sorted { $0.key < $1.key }
        let slots = Slots<[T]>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            slots.set(i, body(items[i].key, items[i].value))
        }
        return slots.values.flatMap { $0 }
    }

    final class Slots<T: Sendable>: @unchecked Sendable {
        private var storage: [T?]
        private let lock = NSLock()
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ v: T) { lock.lock(); storage[i] = v; lock.unlock() }
        var values: [T] { storage.compactMap { $0 } }
        func value(_ i: Int) -> T? { storage[i] }
    }
}
