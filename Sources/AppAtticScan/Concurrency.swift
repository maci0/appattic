import Foundation
/// Slot buffer for `pmap`. A captured local `var` array would be written through
/// its closure box, and Swift's exclusivity check on that box is not lock
/// aware: two workers storing at once trip "Simultaneous accesses" in a debug
/// build and leave the write unordered in a release one. A class-owned array
/// under one lock has neither problem.
private final class PmapSlots<R>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [R?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ value: R, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func collected() -> [R] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { $0! }
    }
}

/// Map over `items` in parallel, preserving input order. `workers` bounds how
/// many calls to `fn` run at once; `concurrentPerform` still gets one iteration
/// per item, with a semaphore holding the rest. A single item or a `workers`
/// value of 1 or less runs inline.
public func pmap<T, R>(_ items: [T], workers: Int = 16, _ fn: (T) -> R) -> [R] {
    guard !items.isEmpty else { return [] }
    if items.count == 1 || workers <= 1 { return items.map(fn) }
    let slots = PmapSlots<R>(count: items.count)
    let sem = DispatchSemaphore(value: max(workers, 1))
    // `concurrentPerform` keeps `fn` non-escaping end to end. Handing it to
    // `queue.async` needs `withoutActuallyEscaping`, whose runtime check is
    // racy: a dispatched block can outlive the join, so the check aborts the
    // process with "non-escaping closure has escaped" mid-scan.
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        sem.wait()
        slots.set(fn(items[i]), at: i)
        sem.signal()
    }
    return slots.collected()
}

/// Split into consecutive runs of at most `n` elements.
func chunked<T>(_ xs: [T], into n: Int) -> [[T]] {
    guard n > 0 else { return [] }
    var out: [[T]] = []
    out.reserveCapacity((xs.count + n - 1) / n)
    var i = 0
    while i < xs.count {
        out.append(Array(xs[i..<min(i + n, xs.count)]))
        i += n
    }
    return out
}
