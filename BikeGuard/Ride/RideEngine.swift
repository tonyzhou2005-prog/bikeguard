import Darwin
import Foundation

/// `Darwin.flock` is the `struct flock` initializer in the Swift overlay, not the
/// POSIX lock function. Call the C symbol directly.
@_silgen_name("flock")
private func bikeguardPOSIXLock(_ fd: Int32, _ operation: Int32) -> Int32

protocol RideClock {
    func now() -> Date
}

struct SystemRideClock: RideClock {
    func now() -> Date { Date() }
}

protocol RideReminderScheduling: AnyObject {
    func replaceReminders(with reminders: [RideReminderPlan])
    func cancelReminders()
}

/// Owns ride transitions. Every read and write goes through the store, so a
/// process that was killed restores the same start time. The file lock is
/// held across the read-modify-write so a Shortcuts intent and the UI cannot
/// both start a ride.
final class RideEngine {
    private let store: RideStoring
    private let clock: RideClock
    private let reminders: RideReminderScheduling
    private let lockURL: URL

    init(
        store: RideStoring,
        clock: RideClock,
        reminders: RideReminderScheduling,
        lockURL: URL? = nil
    ) {
        self.store = store
        self.clock = clock
        self.reminders = reminders
        self.lockURL = lockURL ?? Self.defaultLockURL()
    }

    static let shared = RideEngine(
        store: UserDefaultsRideStore(),
        clock: SystemRideClock(),
        reminders: SystemReminderScheduler()
    )

    func snapshot() -> RideSnapshot {
        withLock {
            let now = clock.now()
            let session = store.load()
            return RideSnapshot(session: session, phase: RidePolicy.phase(of: session, now: now), now: now)
        }
    }

    @discardableResult
    func start() -> StartOutcome {
        withLock {
            let now = clock.now()
            let decision = RidePolicy.decideStart(existing: store.load(), now: now)
            guard decision.outcome == .started else { return .alreadyActive }
            store.save(decision.session)
            reminders.replaceReminders(with: decision.remindersToSchedule)
            return .started
        }
    }

    /// Ends the active ride and cancels pending reminders.
    /// Returns false when no ride is active.
    @discardableResult
    func end() -> Bool {
        withLock {
            let now = clock.now()
            guard let ended = RidePolicy.endedSession(existing: store.load(), now: now) else {
                return false
            }
            store.save(ended)
            reminders.cancelReminders()
            return true
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        let directory = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return try body() }
        _ = bikeguardPOSIXLock(fd, LOCK_EX)
        defer {
            _ = bikeguardPOSIXLock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        return try body()
    }

    private static func defaultLockURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("bikeguard.lock")
    }
}
