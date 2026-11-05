import Foundation

@main
struct LockStateTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 100)
        var state = LockState.idle
        var calls = 0

        state.request(isLocked: false, at: now) { calls += 1; return false }
        assert(state == .failed, "A failed request must never claim the screen is locked")
        state.update(isLocked: false, at: now.addingTimeInterval(2))
        assert(state == .failed)

        state.request(isLocked: false, at: now) { calls += 1; return true }
        assert(state.isRequesting, "Submitting a request is not confirmation")
        state.update(isLocked: false, at: now.addingTimeInterval(2))
        assert(state.isRequesting)
        state.update(isLocked: false, at: now.addingTimeInterval(4))
        assert(state == .failed, "An unconfirmed request must time out")

        state.request(isLocked: false, at: now) { calls += 1; return true }
        state.update(isLocked: true, at: now.addingTimeInterval(2))
        assert(state == .locked)
        state.update(isLocked: false, at: now.addingTimeInterval(4))
        assert(state == .idle, "Unlocking must clear the locked state")

        state.request(isLocked: true, at: now) { calls += 1; return false }
        assert(state == .locked)
        assert(calls == 3, "Do not send another request when already locked")

        state = .failed
        state.update(isLocked: true, at: now)
        assert(state == .locked, "A later confirmed lock must replace a failure")
        print("PASS: failed request, pending confirmation, timeout, confirmed lock, unlock, retry")
    }
}
