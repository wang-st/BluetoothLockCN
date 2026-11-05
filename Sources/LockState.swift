import Foundation

enum LockState: Equatable {
    case idle
    case requesting(since: Date)
    case locked
    case failed

    var isRequesting: Bool {
        if case .requesting = self { return true }
        return false
    }

    mutating func request(isLocked: Bool, at now: Date, perform: () -> Bool) {
        if isLocked {
            self = .locked
        } else {
            // A successful call only submits a request; the session must confirm the lock.
            self = perform() ? .requesting(since: now) : .failed
        }
    }

    mutating func update(isLocked: Bool, at now: Date) {
        if isLocked {
            self = .locked
        } else if self == .locked {
            self = .idle
        } else if case .requesting(let since) = self, now.timeIntervalSince(since) >= 4 {
            self = .failed
        }
    }
}
