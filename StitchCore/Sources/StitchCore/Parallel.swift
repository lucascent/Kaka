import Foundation

/// Runs `work` once per index with bounded in-flight concurrency and returns every settled
/// result in input order, so callers can rethrow the first failure exactly like a serial loop.
func boundedSettledResults<Value: Sendable>(
    count: Int, concurrency: Int,
    work: @escaping @Sendable (Int) async -> Result<Value, Error>
) async -> [Result<Value, Error>] {
    guard count > 0 else { return [] }
    let limit = min(max(1, concurrency), count)
    return await withTaskGroup(of: (Int, Result<Value, Error>).self) { group in
        var results = [Result<Value, Error>?](repeating: nil, count: count)
        var next = 0
        while next < limit {
            let index = next
            group.addTask { (index, await work(index)) }
            next += 1
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < count {
                let following = next
                group.addTask { (following, await work(following)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
