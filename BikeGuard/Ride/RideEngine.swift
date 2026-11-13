import Darwin
import Foundation

/// `Darwin.flock` is the `struct flock` initializer in the Swift overlay, not the
/// POSIX lock function. Call the C symbol directly.
@_silgen_name("flock")
private func bikeguardPOSIXLock(_ fd: Int32, _ operation: Int32) -> Int32

protocol RideClock: Sendable {
    func now() -> Date
}

struct SystemRideClock: RideClock {
    func now() -> Date { Date() }
}

enum ReminderRegistrationStatus: Equatable, Sendable {
    case full
    case partial
    case failed
}

struct ReminderRegistrationResult: Equatable, Sendable {
    var status: ReminderRegistrationStatus
    var succeededOffsets: [TimeInterval]
    var failedOffsets: [TimeInterval]
    /// Offsets submitted to the notification center during this call.
    var addedOffsets: [TimeInterval]

    static func make(
        succeeded: [TimeInterval],
        failed: [TimeInterval],
        added: [TimeInterval]
    ) -> ReminderRegistrationResult {
        let status: ReminderRegistrationStatus
        if failed.isEmpty {
            status = .full
        } else if succeeded.isEmpty {
            status = .failed
        } else {
            status = .partial
        }
        return ReminderRegistrationResult(
            status: status,
            succeededOffsets: succeeded,
            failedOffsets: failed,
            addedOffsets: added
        )
    }

    static let untouched = ReminderRegistrationResult.make(succeeded: [], failed: [], added: [])
}

struct StartResult: Equatable, Sendable {
    var outcome: StartOutcome
    var registration: ReminderRegistrationResult
}

/// Owns ride transitions and is the only type that mutates reminders.
///
/// Start, end, and repair all run here. The notification-center calls are
/// async, so another operation can run while one is suspended. After every
/// await the coordinator reloads the persisted session and mutates reminders
/// only when the id it captured is still the active ride. Delays are computed
/// from `clock.now()` immediately before each add, not from an earlier snapshot.
actor RideNotificationCoordinator {
    private let store: RideStoring
    private let clock: RideClock
    private let center: RideNotificationCenter
    private let lockURL: URL

    init(store: RideStoring, clock: RideClock, center: RideNotificationCenter, lockURL: URL) {
        self.store = store
        self.clock = clock
        self.center = center
        self.lockURL = lockURL
    }

    func start() async -> StartResult {
        let prepared: PreparedStart = withLock {
            let now = clock.now()
            let decision = RidePolicy.decideStart(existing: store.load(), now: now)
            if decision.outcome == .started {
                var session = decision.session
                session.registration = .pending
                store.save(session)
                return .begin(session)
            }
            return .keep(decision.session)
        }

        switch prepared {
        case .begin(let session):
            await center.discardExistingReminders()
            guard activeSession(id: session.id) != nil else {
                return StartResult(outcome: .started, registration: .untouched)
            }
            let registration = await registerMissing(sessionID: session.id)
            return StartResult(outcome: .started, registration: registration)
        case .keep(let session):
            let registration = await registerMissing(sessionID: session.id)
            return StartResult(outcome: .alreadyActive, registration: registration)
        }
    }

    func end() async -> Bool {
        let didEnd = withLock { () -> Bool in
            let now = clock.now()
            guard let ended = RidePolicy.endedSession(existing: store.load(), now: now) else {
                return false
            }
            store.save(ended)
            return true
        }
        guard didEnd else { return false }
        await center.cancelReminders()
        return true
    }

    func repair() async -> ReminderRegistrationResult {
        let sessionID: UUID? = withLock { store.load().flatMap { session in
            RidePolicy.isActive(session, now: clock.now()) ? session.id : nil
        } }
        guard let sessionID else { return .untouched }
        return await registerMissing(sessionID: sessionID)
    }

    /// Adds future reminders for `sessionID` that are not already pending.
    /// Does not remove reminders that are already registered.
    private func registerMissing(sessionID: UUID) async -> ReminderRegistrationResult {
        let pendingIDs = await center.pendingIdentifiers()
        guard let session = activeSession(id: sessionID) else { return .untouched }
        let plans = RidePolicy.reminders(forStart: session.startedAt)
        var succeeded: [TimeInterval] = []
        var failed: [TimeInterval] = []
        var added: [TimeInterval] = []

        for plan in plans {
            guard activeSession(id: sessionID) != nil else { break }
            let now = clock.now()
            let delay = plan.fireAt.timeIntervalSince(now)
            if delay <= 1 {
                continue
            }
            if pendingIDs.contains(plan.identifier) {
                succeeded.append(plan.offset)
                continue
            }
            let request = RideNotificationRequest(
                identifier: plan.identifier,
                offset: plan.offset,
                fireAt: plan.fireAt,
                delay: delay,
                title: plan.title,
                body: plan.body
            )
            do {
                try await center.add(request)
                guard let current = activeSession(id: sessionID) else {
                    await undoStaleAdd(request: request, expectedID: sessionID)
                    break
                }
                _ = current
                succeeded.append(plan.offset)
                added.append(plan.offset)
            } catch {
                failed.append(plan.offset)
            }
        }

        let result = ReminderRegistrationResult.make(succeeded: succeeded, failed: failed, added: added)
        persist(result, for: sessionID)
        return result
    }

    /// A late add uses the fixed reminder id and can overwrite the next ride.
    /// If this session is no longer current, put the center back in line with
    /// whatever ride is active now, or drop the reminder if none is.
    private func undoStaleAdd(request: RideNotificationRequest, expectedID: UUID) async {
        let current = withLock { store.load() }
        guard let current, current.id != expectedID, RidePolicy.isActive(current, now: clock.now()) else {
            await center.removePending(identifiers: [request.identifier])
            return
        }
        let now = clock.now()
        guard let plan = RidePolicy.reminders(forStart: current.startedAt).first(where: { $0.identifier == request.identifier }) else {
            return
        }
        let delay = plan.fireAt.timeIntervalSince(now)
        guard delay > 1 else {
            await center.removePending(identifiers: [request.identifier])
            return
        }
        let replacement = RideNotificationRequest(
            identifier: plan.identifier,
            offset: plan.offset,
            fireAt: plan.fireAt,
            delay: delay,
            title: plan.title,
            body: plan.body
        )
        try? await center.add(replacement)
    }

    private func persist(_ result: ReminderRegistrationResult, for sessionID: UUID) {
        withLock {
            guard var session = store.load(), session.id == sessionID, session.endedAt == nil else { return }
            switch result.status {
            case .full:
                session.registration = .complete
            case .partial:
                session.registration = .partial(succeededOffsets: result.succeededOffsets)
            case .failed:
                session.registration = .pending
            }
            store.save(session)
        }
    }

    private func activeSession(id: UUID) -> RideSession? {
        withLock {
            let now = clock.now()
            guard let session = store.load(), session.id == id, RidePolicy.isActive(session, now: now) else {
                return nil
            }
            return session
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        rideWithFileLock(lockURL, body)
    }

    private enum PreparedStart {
        case begin(RideSession)
        case keep(RideSession)
    }
}

final class RideEngine {
    private let store: RideStoring
    private let clock: RideClock
    private let lockURL: URL
    private let coordinator: RideNotificationCoordinator

    init(
        store: RideStoring,
        clock: RideClock,
        center: RideNotificationCenter,
        lockURL: URL? = nil
    ) {
        let resolvedLock = lockURL ?? Self.defaultLockURL()
        self.store = store
        self.clock = clock
        self.lockURL = resolvedLock
        self.coordinator = RideNotificationCoordinator(
            store: store,
            clock: clock,
            center: center,
            lockURL: resolvedLock
        )
    }

    static let shared = RideEngine(
        store: UserDefaultsRideStore(),
        clock: SystemRideClock(),
        center: SystemRideNotificationCenter()
    )

    func snapshot() -> RideSnapshot {
        rideWithFileLock(lockURL) {
            let now = clock.now()
            let session = store.load()
            return RideSnapshot(session: session, phase: RidePolicy.phase(of: session, now: now), now: now)
        }
    }

    func start() async -> StartResult {
        await coordinator.start()
    }

    @discardableResult
    func end() async -> Bool {
        await coordinator.end()
    }

    @discardableResult
    func repair() async -> ReminderRegistrationResult {
        await coordinator.repair()
    }

    private static func defaultLockURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("bikeguard.lock")
    }
}

private func rideWithFileLock<T>(_ lockURL: URL, _ body: () throws -> T) rethrows -> T {
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
