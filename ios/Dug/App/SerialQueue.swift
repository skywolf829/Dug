import Foundation

/// Runs async jobs one at a time, in the order they were submitted.
@MainActor
final class SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await job.result }
        return try await job.value
    }
}
