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

    // Hardening (security run-2): the write must not hold the lease's lock, or a main-actor
    // revoke during a slow write blocks the UI. A revoke during an in-flight write lands after it.
    @Test("A revoke during an in-flight commit returns at once and leaves the commit standing")
    func revokeDuringCommitDoesNotBlock() {
        let lease = ExportLease()
        let events = Mutex<[String]>([])
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread {
            _ = lease.whileValid {
                started.signal()
                finish.wait()
                events.withLock { $0.append("committed") }
            }
            done.signal()
        }.start()
        started.wait()
        lease.revoke()  // must not wait for the write
        events.withLock { $0.append("revoked") }
        finish.signal()
        done.wait()
        #expect(events.withLock { $0 } == ["revoked", "committed"])
        #expect(lease.isCommitted)
        #expect(!lease.isRevoked)
    }

    @Test("A commit that fails after a revoke was requested ends revoked")
    func failedCommitHonorsRevoke() {
        struct WriteFailed: Error {}
        let lease = ExportLease()
        let result: Int?? = try? lease.whileValid {
            lease.revoke()
            throw WriteFailed()
        }
        #expect(result == nil)
        #expect(lease.isRevoked)
        #expect(lease.whileValid { 1 } == nil)
    }

    @Test("A committed lease accepts no second commit")
    func singleCommit() {
        let lease = ExportLease()
        #expect(lease.whileValid { 1 } == 1)
        #expect(lease.whileValid { 2 } == nil)
    }
}
