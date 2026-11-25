import XCTest

@testable import file_saver_ffi

final class KeyedLockTests: XCTestCase {
    func testWorkOfOneKeyRunsOneAtATime() {
        let lock = KeyedLock()
        var taken = Set<Int>()
        var picked = [Int]()
        let record = NSLock()

        // Each picks the first free number and then takes it, like a save that
        // checks for a name and then creates the file: without the lock they
        // would pick the same one.
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            lock.withLock("leg.png") {
                let number = (0...).first { !taken.contains($0) }!
                Thread.sleep(forTimeInterval: 0.002)
                taken.insert(number)
                record.lock()
                picked.append(number)
                record.unlock()
            }
        }

        XCTAssertEqual(picked.sorted(), Array(0..<20))
    }

    func testWorkOfDifferentKeysRunsAtTheSameTime() {
        let lock = KeyedLock()
        let bothInside = DispatchGroup()
        bothInside.enter()
        bothInside.enter()
        let done = expectation(description: "both keys ran")
        done.expectedFulfillmentCount = 2

        for key in ["a.png", "b.png"] {
            DispatchQueue.global().async {
                lock.withLock(key) {
                    bothInside.leave()
                    // Returns only once the other key is inside its lock too.
                    XCTAssertEqual(bothInside.wait(timeout: .now() + 5), .success)
                }
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10)
    }

    func testReleasesTheKeyWhenTheWorkThrows() {
        struct Failure: Error {}
        let lock = KeyedLock()

        XCTAssertThrowsError(try lock.withLock("leg.png") { throw Failure() })

        XCTAssertEqual(lock.withLock("leg.png") { 1 }, 1)
    }
}
