import Foundation
/// Map over `items` in parallel, preserving input order. `workers` bounds how
/// many calls to `fn` run at once; `concurrentPerform` still gets one iteration
/// per item, with a semaphore holding the rest. A single item or a `workers`
/// value of 1 or less runs inline.
public func pmap<T, R>(_ items: [T], workers: Int = 16, _ fn: (T) -> R) -> [R] {
    guard !items.isEmpty else { return [] }
    if items.count == 1 || workers <= 1 { return items.map(fn) }
    var results = [R?](repeating: nil, count: items.count)
    let lock = NSLock()
    let sem = DispatchSemaphore(value: max(workers, 1))
    // `concurrentPerform` keeps `fn` non-escaping end to end. Handing it to
    // `queue.async` needs `withoutActuallyEscaping`, whose runtime check is
    // racy: a dispatched block can outlive the join, so the check aborts the
    // process with "non-escaping closure has escaped" mid-scan.
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        sem.wait()
        let value = fn(items[i])
        lock.lock()
        results[i] = value
        lock.unlock()
        sem.signal()
    }
    return results.map { $0! }
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
