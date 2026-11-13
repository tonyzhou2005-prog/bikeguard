import XCTest
@testable import BikeGuard

final class ManualClock: RideClock, @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
    func now() -> Date { date }
}

final class RecordingNotificationCenter: RideNotificationCenter, @unchecked Sendable {
    private(set) var pending: [RideNotificationRequest] = []
    private(set) var cancelCount = 0
    private(set) var additionCount = 0

    func pendingIdentifiers() async -> Set<String> {
        Set(pending.map(\.identifier))
    }

    func removePending(identifiers: [String]) async {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDelivered(identifiers: [String]) async {}

    func add(_ request: RideNotificationRequest) async throws {
        additionCount += 1
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func cancelReminders() async {
        cancelCount += 1
        pending.removeAll()
    }
}

final class RidePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreeWindowGraceAndReminderConstants() {
        XCTAssertEqual(RidePolicy.freeWindow, 60 * 60)
        XCTAssertEqual(RidePolicy.gracePeriod, 30 * 60)
        XCTAssertEqual(RidePolicy.activeLifetime, 90 * 60)
        XCTAssertEqual(RidePolicy.reminderOffsets, [45 * 60, 50 * 60, 55 * 60])
        XCTAssertEqual(
            RidePolicy.reminderIdentifiers,
            ["bikeguard.reminder.45", "bikeguard.reminder.50", "bikeguard.reminder.55"]
        )
    }

    func testStartOnIdleSchedules45_50_55() {
        let decision = RidePolicy.decideStart(existing: nil, now: start)
        XCTAssertEqual(decision.outcome, .started)
        XCTAssertEqual(decision.session.startedAt, start)
        XCTAssertNil(decision.session.endedAt)
        XCTAssertEqual(decision.remindersToSchedule.map(\.offset), [45 * 60, 50 * 60, 55 * 60])
        XCTAssertEqual(decision.remindersToSchedule.map(\.fireAt), [
            start.addingTimeInterval(45 * 60),
            start.addingTimeInterval(50 * 60),
            start.addingTimeInterval(55 * 60)
        ])
        XCTAssertEqual(decision.remindersToSchedule.map(\.identifier), RidePolicy.reminderIdentifiers)
        XCTAssertEqual(decision.remindersToSchedule.map(\.title), ["该锁车了吗？", "该锁车了吗？", "该锁车了吗？"])
        XCTAssertTrue(decision.remindersToSchedule[0].body.contains("45 分钟"))
        XCTAssertTrue(decision.remindersToSchedule[0].body.contains("15 分钟"))
        XCTAssertTrue(decision.remindersToSchedule[1].body.contains("50 分钟"))
        XCTAssertTrue(decision.remindersToSchedule[1].body.contains("10 分钟"))
        XCTAssertTrue(decision.remindersToSchedule[2].body.contains("55 分钟"))
        XCTAssertTrue(decision.remindersToSchedule[2].body.contains("5 分钟"))
    }

    func testRestartWhileRidingIsNoOp() {
        let existing = RideSession(startedAt: start, endedAt: nil)
        let later = start.addingTimeInterval(10 * 60)
        let decision = RidePolicy.decideStart(existing: existing, now: later)
        XCTAssertEqual(decision.outcome, .alreadyActive)
        XCTAssertEqual(decision.session, existing)
        XCTAssertTrue(decision.remindersToSchedule.isEmpty)
        XCTAssertEqual(RidePolicy.remainingTime(session: decision.session, now: later), 50 * 60, accuracy: 0.001)
    }

    func testRestartDuringGraceIsNoOp() {
        let existing = RideSession(startedAt: start, endedAt: nil)
        let later = start.addingTimeInterval(70 * 60)
        let decision = RidePolicy.decideStart(existing: existing, now: later)
        XCTAssertEqual(decision.outcome, .alreadyActive)
        XCTAssertEqual(decision.session.startedAt, start)
        XCTAssertTrue(decision.remindersToSchedule.isEmpty)
        XCTAssertEqual(RidePolicy.remainingTime(session: existing, now: later), 0, accuracy: 0.001)
        guard case .grace(let overtime) = RidePolicy.phase(of: existing, now: later) else {
            return XCTFail("expected grace")
        }
        XCTAssertEqual(overtime, 10 * 60, accuracy: 0.001)
    }

    func testRestartAfterGraceStartsNewRide() {
        let existing = RideSession(startedAt: start, endedAt: nil)
        let later = start.addingTimeInterval(90 * 60)
        XCTAssertEqual(RidePolicy.phase(of: existing, now: later), .expiredAutomatically)
        XCTAssertFalse(RidePolicy.isActive(existing, now: later))
        let decision = RidePolicy.decideStart(existing: existing, now: later)
        XCTAssertEqual(decision.outcome, .started)
        XCTAssertEqual(decision.session.startedAt, later)
        XCTAssertEqual(decision.remindersToSchedule.map(\.offset), RidePolicy.reminderOffsets)
        XCTAssertEqual(decision.remindersToSchedule.first?.fireAt, later.addingTimeInterval(45 * 60))
    }

    func testRestartAfterManualEndStartsNewRide() {
        let ended = RideSession(startedAt: start, endedAt: start.addingTimeInterval(5 * 60))
        let later = start.addingTimeInterval(6 * 60)
        XCTAssertFalse(RidePolicy.isActive(ended, now: later))
        let decision = RidePolicy.decideStart(existing: ended, now: later)
        XCTAssertEqual(decision.outcome, .started)
        XCTAssertEqual(decision.session.startedAt, later)
        XCTAssertNil(decision.session.endedAt)
        XCTAssertEqual(decision.remindersToSchedule.count, 3)
    }

    func testRemainingTimeSamples() {
        let session = RideSession(startedAt: start, endedAt: nil)
        let samples: [(TimeInterval, TimeInterval)] = [
            (0, 60 * 60),
            (1, 60 * 60 - 1),
            (15 * 60, 45 * 60),
            (45 * 60, 15 * 60),
            (50 * 60, 10 * 60),
            (55 * 60, 5 * 60),
            (59 * 60 + 59, 1),
            (60 * 60, 0),
            (70 * 60, 0),
            (90 * 60, 0),
            (120 * 60, 0)
        ]
        for (elapsed, expected) in samples {
            let now = start.addingTimeInterval(elapsed)
            XCTAssertEqual(
                RidePolicy.remainingTime(session: session, now: now),
                expected,
                accuracy: 0.001,
                "elapsed \(elapsed)"
            )
        }
    }

    func testRemainingTimeIsZeroWhenIdleEndedOrPastWindow() {
        XCTAssertEqual(RidePolicy.remainingTime(session: nil, now: start), 0)
        let ended = RideSession(startedAt: start, endedAt: start.addingTimeInterval(10))
        XCTAssertEqual(
            RidePolicy.remainingTime(session: ended, now: start.addingTimeInterval(20)),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(RidePolicy.phase(of: nil, now: start), .idle)
        XCTAssertEqual(RidePolicy.phase(of: ended, now: start.addingTimeInterval(20)), .endedManually)
    }

    func testPhaseTransitionsThroughExpiry() {
        let session = RideSession(startedAt: start, endedAt: nil)
        XCTAssertEqual(RidePolicy.phase(of: session, now: start), .riding(remaining: 60 * 60))
        XCTAssertEqual(
            RidePolicy.phase(of: session, now: start.addingTimeInterval(60 * 60 - 1)),
            .riding(remaining: 1)
        )
        XCTAssertEqual(RidePolicy.phase(of: session, now: start.addingTimeInterval(60 * 60)), .grace(overtime: 0))
        XCTAssertEqual(
            RidePolicy.phase(of: session, now: start.addingTimeInterval(90 * 60 - 1)),
            .grace(overtime: 30 * 60 - 1)
        )
        XCTAssertTrue(RidePolicy.isActive(session, now: start.addingTimeInterval(90 * 60 - 1)))
        XCTAssertEqual(RidePolicy.phase(of: session, now: start.addingTimeInterval(90 * 60)), .expiredAutomatically)
        XCTAssertFalse(RidePolicy.isActive(session, now: start.addingTimeInterval(90 * 60)))
    }

    func testEndOnlyWhileActive() {
        let session = RideSession(startedAt: start, endedAt: nil)
        let ended = RidePolicy.endedSession(existing: session, now: start.addingTimeInterval(12 * 60))
        XCTAssertEqual(ended?.endedAt, start.addingTimeInterval(12 * 60))
        XCTAssertEqual(ended?.startedAt, start)
        XCTAssertNil(RidePolicy.endedSession(existing: nil, now: start))
        XCTAssertNil(RidePolicy.endedSession(existing: ended, now: start.addingTimeInterval(13 * 60)))
        let expired = RideSession(startedAt: start, endedAt: nil)
        XCTAssertNil(RidePolicy.endedSession(existing: expired, now: start.addingTimeInterval(90 * 60)))
    }

    func testSessionJSONRoundTrip() throws {
        let session = RideSession(startedAt: start, endedAt: start.addingTimeInterval(40 * 60))
        let data = try RideCoding.encoder.encode(session)
        let decoded = try RideCoding.decoder.decode(RideSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }
}

final class RideEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testStartPersistsAndSchedulesOnce() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, _) = makeEngine(now: start, scheduler: scheduler)
        let result = await engine.start()
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.registration.status, .full)
        let snapshot = engine.snapshot()
        XCTAssertEqual(snapshot.session?.startedAt, start)
        XCTAssertNil(snapshot.session?.endedAt)
        XCTAssertEqual(snapshot.session?.registration, .complete)
        XCTAssertEqual(snapshot.phase, .riding(remaining: 60 * 60))
        XCTAssertEqual(snapshot.remaining, 60 * 60, accuracy: 0.001)
        XCTAssertEqual(scheduler.pending.map(\.offset), [45 * 60, 50 * 60, 55 * 60])
        XCTAssertEqual(scheduler.additionCount, 3)
        XCTAssertEqual(scheduler.cancelCount, 0)
    }

    func testIdempotentRestartKeepsOriginalStartAndDoesNotReschedule() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, clock) = makeEngine(now: start, scheduler: scheduler)
        let first = await engine.start()
        XCTAssertEqual(first.outcome, .started)
        clock.date = start.addingTimeInterval(20 * 60)
        let second = await engine.start()
        XCTAssertEqual(second.outcome, .alreadyActive)
        XCTAssertTrue(second.registration.addedOffsets.isEmpty)
        clock.date = start.addingTimeInterval(70 * 60)
        let third = await engine.start()
        XCTAssertEqual(third.outcome, .alreadyActive)
        XCTAssertTrue(third.registration.addedOffsets.isEmpty)
        XCTAssertEqual(engine.snapshot().session?.startedAt, start)
        XCTAssertNil(engine.snapshot().session?.endedAt)
        XCTAssertEqual(engine.snapshot().remaining, 0, accuracy: 0.001)
        XCTAssertEqual(scheduler.additionCount, 3, "a second start must not schedule another set")
        XCTAssertEqual(scheduler.cancelCount, 0)
    }

    func testEndCancelsRemindersAndPersists() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, clock) = makeEngine(now: start, scheduler: scheduler)
        let started = await engine.start()
        XCTAssertEqual(started.outcome, .started)
        clock.date = start.addingTimeInterval(15 * 60)
        let ended = await engine.end()
        XCTAssertTrue(ended)
        let snapshot = engine.snapshot()
        XCTAssertEqual(snapshot.phase, .endedManually)
        XCTAssertEqual(snapshot.session?.endedAt, clock.date)
        XCTAssertEqual(snapshot.remaining, 0, accuracy: 0.001)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertTrue(scheduler.pending.isEmpty)
        let endedAgain = await engine.end()
        XCTAssertFalse(endedAgain)
        XCTAssertEqual(scheduler.cancelCount, 1)
    }

    func testEndWhenInactiveIsNoOp() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, _) = makeEngine(now: start, scheduler: scheduler)
        let ended = await engine.end()
        XCTAssertFalse(ended)
        XCTAssertEqual(scheduler.cancelCount, 0)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertEqual(scheduler.additionCount, 0)
        XCTAssertEqual(engine.snapshot().phase, .idle)
    }

    func testEndDuringGraceStillCancels() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, clock) = makeEngine(now: start, scheduler: scheduler)
        _ = await engine.start()
        clock.date = start.addingTimeInterval(80 * 60)
        XCTAssertTrue(engine.snapshot().isActive)
        let ended = await engine.end()
        XCTAssertTrue(ended)
        XCTAssertEqual(engine.snapshot().phase, .endedManually)
        XCTAssertEqual(scheduler.cancelCount, 1)
    }

    func testNewStartAfterEndOrExpirySchedulesFreshReminders() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, clock) = makeEngine(now: start, scheduler: scheduler)
        _ = await engine.start()
        clock.date = start.addingTimeInterval(5 * 60)
        let ended = await engine.end()
        XCTAssertTrue(ended)
        clock.date = start.addingTimeInterval(6 * 60)
        let restarted = await engine.start()
        XCTAssertEqual(restarted.outcome, .started)
        XCTAssertEqual(engine.snapshot().session?.startedAt, clock.date)
        XCTAssertEqual(scheduler.pending.map(\.fireAt), [
            clock.date.addingTimeInterval(45 * 60),
            clock.date.addingTimeInterval(50 * 60),
            clock.date.addingTimeInterval(55 * 60)
        ])

        clock.date = clock.date.addingTimeInterval(90 * 60)
        XCTAssertEqual(engine.snapshot().phase, .expiredAutomatically)
        let newStart = clock.date
        let restartedAgain = await engine.start()
        XCTAssertEqual(restartedAgain.outcome, .started)
        XCTAssertEqual(engine.snapshot().session?.startedAt, newStart)
        XCTAssertEqual(scheduler.pending.map(\.fireAt), [
            newStart.addingTimeInterval(45 * 60),
            newStart.addingTimeInterval(50 * 60),
            newStart.addingTimeInterval(55 * 60)
        ])
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertEqual(scheduler.additionCount, 9)
    }

    func testRemainingTimeFollowsInjectedClock() async {
        let scheduler = RecordingNotificationCenter()
        let (engine, clock) = makeEngine(now: start, scheduler: scheduler)
        _ = await engine.start()
        clock.date = start.addingTimeInterval(15 * 60)
        XCTAssertEqual(engine.snapshot().remaining, 45 * 60, accuracy: 0.001)
        clock.date = start.addingTimeInterval(55 * 60)
        XCTAssertEqual(engine.snapshot().remaining, 5 * 60, accuracy: 0.001)
        clock.date = start.addingTimeInterval(60 * 60)
        XCTAssertEqual(engine.snapshot().remaining, 0, accuracy: 0.001)
        XCTAssertEqual(engine.snapshot().phase, .grace(overtime: 0))
    }

    func testUserDefaultsRoundTripRestoresRemainingTime() async throws {
        let suite = "BikeGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let scheduler = RecordingNotificationCenter()
        let clock = ManualClock(date: start)
        let store = UserDefaultsRideStore(defaults: defaults)
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("bikeguard-\(UUID().uuidString).lock")
        let engine = RideEngine(store: store, clock: clock, center: scheduler, lockURL: lock)
        let started = await engine.start()
        XCTAssertEqual(started.outcome, .started)

        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsRideStore.storageKey))
        let decoded = try RideCoding.decoder.decode(RideSession.self, from: data)
        XCTAssertEqual(decoded.startedAt, start)
        XCTAssertNil(decoded.endedAt)
        XCTAssertEqual(decoded.registration, .complete)

        clock.date = start.addingTimeInterval(20 * 60)
        let restoredStore = UserDefaultsRideStore(defaults: defaults)
        let restoredScheduler = RecordingNotificationCenter()
        let restored = RideEngine(store: restoredStore, clock: clock, center: restoredScheduler, lockURL: lock)
        XCTAssertEqual(restored.snapshot().session?.startedAt, start)
        XCTAssertEqual(restored.snapshot().session?.id, decoded.id)
        XCTAssertEqual(restored.snapshot().remaining, 40 * 60, accuracy: 0.001)
        let again = await restored.start()
        XCTAssertEqual(again.outcome, .alreadyActive)
        XCTAssertEqual(restored.snapshot().session?.startedAt, start)
        XCTAssertEqual(restoredScheduler.pending.map(\.offset), [45 * 60, 50 * 60, 55 * 60])
        XCTAssertEqual(scheduler.additionCount, 3)
    }

    func testCorruptPersistenceIsTreatedAsNoRide() throws {
        let suite = "BikeGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsRideStore.storageKey)
        let store = UserDefaultsRideStore(defaults: defaults)
        XCTAssertNil(store.load())
    }

    func testMemoryStoreRoundTripAcrossEngines() async {
        let store = MemoryRideStore()
        let clock = ManualClock(date: start)
        let firstScheduler = RecordingNotificationCenter()
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("bikeguard-\(UUID().uuidString).lock")
        let first = RideEngine(store: store, clock: clock, center: firstScheduler, lockURL: lock)
        _ = await first.start()
        clock.date = start.addingTimeInterval(25 * 60)
        let secondCenter = RecordingNotificationCenter()
        let second = RideEngine(store: store, clock: clock, center: secondCenter, lockURL: lock)
        XCTAssertEqual(second.snapshot().session?.startedAt, start)
        XCTAssertEqual(second.snapshot().remaining, 35 * 60, accuracy: 0.001)
        let secondStart = await second.start()
        XCTAssertEqual(secondStart.outcome, .alreadyActive)
        XCTAssertEqual(second.snapshot().session?.startedAt, start)
    }

    private func makeEngine(
        now: Date,
        scheduler: RecordingNotificationCenter,
        store: RideStoring = MemoryRideStore()
    ) -> (RideEngine, ManualClock) {
        let clock = ManualClock(date: now)
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("bikeguard-\(UUID().uuidString).lock")
        let engine = RideEngine(store: store, clock: clock, center: scheduler, lockURL: lock)
        return (engine, clock)
    }
}
