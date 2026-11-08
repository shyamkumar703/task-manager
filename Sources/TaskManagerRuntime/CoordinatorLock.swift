import CLocalSupport
import Foundation
import TaskManagerCore

public final class CoordinatorLock: Sendable {
    private let descriptor: Int32
    public init(stateDirectory: String) throws {
        let path = URL(fileURLWithPath: stateDirectory).appendingPathComponent("coordinator.lock").path
        descriptor = tm_lock_acquire(path)
        guard descriptor >= 0 else { throw ManagerError.conflict("A coordinator already owns this state directory, or its lock cannot be opened") }
    }
    public static func isRunning(stateDirectory: String) -> Bool {
        tm_lock_held(URL(fileURLWithPath: stateDirectory).appendingPathComponent("coordinator.lock").path) == 1
    }
    deinit { tm_lock_release(descriptor) }
}
