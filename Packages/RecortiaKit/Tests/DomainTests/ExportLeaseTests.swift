import Foundation
import Synchronization
import Testing

@testable import Domain

// Failure mode (Codex review): a revoke that lands between the lease check and the write would
// still let stale pixels out. A commit runs under the lease, so revoke lands before or after it.
@Suite("ExportLease orders revocation against commits")
struct ExportLeaseTests {
    @Test("A revoked lease never runs the commit; a valid one does")
    func revokedSkipsCommit() {
        let lease = ExportLease()
        #expect(lease.whileValid { 1 } == 1)
        lease.revoke()
        var ran = false
        #expect(lease.whileValid { ran = true } == nil)
        #expect(!ran)
    }

    @Test("A revoke issued during a commit returns only after the commit finished")
    func revokeWaitsForCommit() {
        let lease = ExportLease()
        let events = Mutex<[String]>([])
        let started = DispatchSemaphore(value: 0)
        let commit = Thread {
            _ = lease.whileValid {
                started.signal()
                Thread.sleep(forTimeInterval: 0.2)
                events.withLock { $0.append("committed") }
            }
        }
        commit.start()
        started.wait()
        lease.revoke()
        events.withLock { $0.append("revoked") }
        #expect(events.withLock { $0 } == ["committed", "revoked"])
    }
}
