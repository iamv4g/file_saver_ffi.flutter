import Foundation

/// Runs the work of one key at a time, across threads; work of different keys
/// runs at the same time.
///
/// Saves to the Photos Library use it to check for an asset of a name and add
/// one as a single step, which Photos can't do by itself.
final class KeyedLock {
    private let condition = NSCondition()
    private var held = Set<String>()

    /// Runs `body` once no other call for `key` is running, blocking the
    /// calling thread until then.
    func withLock<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        condition.lock()
        while held.contains(key) {
            condition.wait()
        }
        held.insert(key)
        condition.unlock()
        defer {
            condition.lock()
            held.remove(key)
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}
