import XCTest
@testable import BikeGuard

final class PausableNotificationCenter: RideNotificationCenter, @unchecked Sendable {
    private let state = NSLock()
    private var stored: [RideNotificationRequest] = []
    private var pauseNextPending = false
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    var failOffsets: Set<TimeInterval> = []

    var pending: [RideNotificationRequest] {
        state.lock()
        defer { state.unlock() }
        return stored
    }

    func pauseBeforeNextPendingRead() {
        state.lock()
        pauseNextPending = true
        state.unlock()
    }

    func waitUntilPendingReadPaused() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.lock()
            if pausedContinuation != nil {
                state.unlock()
                continuation.resume()
                return
            }
            enteredContinuation = continuation
            state.unlock()
        }
    }

    func resumePendingRead() {
        state.lock()
        let continuation = pausedContinuation
        pausedContinuation = nil
        state.unlock()
        continuation?.resume()
    }

    func pendingIdentifiers() async -> Set<String> {
        let shouldPause: Bool = {
            state.lock()
            defer { state.unlock() }
            if pauseNextPending {
                pauseNextPending = false
                return true
            }
            return false
        }()
        if shouldPause {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.lock()
                pausedContinuation = continuation
                let entered = enteredContinuation
                enteredContinuation = nil
                state.unlock()
                entered?.resume()
            }
        }
        state.lock()
        defer { state.unlock() }
        return Set(stored.map(\.identifier))
    }

    func removePending(identifiers: [String]) async {
        state.lock()
        stored.removeAll { identifiers.contains($0.identifier) }
        state.unlock()
    }

    func removeDelivered(identifiers: [String]) async {}

    func cancelReminders() async {
        state.lock()
        stored.removeAll()
        state.unlock()
    }

    func add(_ request: RideNotificationRequest) async throws {
        if failOffsets.contains(request.offset) {
            throw RideNotificationAddError.rejected(offset: request.offset)
        }
        state.lock()
        stored.removeAll { $0.identifier == request.identifier }
        stored.append(request)
        state.unlock()
    }
}

final class NotificationReliabilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let offsets: [TimeInterval] = [45 * 60, 50 * 60, 55 * 60]

    func testRepairPausedThenEndDoesNotRestoreNotifications() async {
        let center = PausableNotificationCenter()
        let (engine, _) = makeEngine(center: center)
        let started = await engine.start()
        XCTAssertEqual(started.outcome, .started)
        XCTAssertEqual(center.pending.map(\.offset), offsets)

        center.pauseBeforeNextPendingRead()
        let repair = Task { await engine.repair() }
        await center.waitUntilPendingReadPaused()
        let ended = await engine.end()
        XCTAssertTrue(ended)
        XCTAssertTrue(center.pending.isEmpty)

        center.resumePendingRead()
        _ = await repair.value
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(engine.snapshot().phase, .endedManually)
    }

    func testStaleRepairDoesNotOverwriteTheNextRide() async throws {
        let center = PausableNotificationCenter()
        let (engine, clock) = makeEngine(center: center)
        let started = await engine.start()
        XCTAssertEqual(started.outcome, .started)
        let originalFires = center.pending.map(\.fireAt)

        center.pauseBeforeNextPendingRead()
        let repair = Task { await engine.repair() }
        await center.waitUntilPendingReadPaused()
        let ended = await engine.end()
        XCTAssertTrue(ended)
        // Three minutes, not ten: a ten-minute shift makes the new 45-minute
        // reminder land on the old ride's 55-minute fire time.
        clock.date = start.addingTimeInterval(3 * 60)
        let restarted = await engine.start()
        XCTAssertEqual(restarted.outcome, .started)
        let newStart = try XCTUnwrap(engine.snapshot().session?.startedAt)
        XCTAssertEqual(newStart, clock.date)

        center.resumePendingRead()
        _ = await repair.value

        XCTAssertEqual(center.pending.map(\.fireAt), expectedFires(from: newStart))
        XCTAssertEqual(center.pending.map(\.offset), offsets)
        for fire in originalFires {
            XCTAssertFalse(center.pending.contains { $0.fireAt == fire })
        }
        XCTAssertEqual(engine.snapshot().session?.startedAt, newStart)
    }

    func testAddFailureIsPartialOrFailedAndRepairSkipsPastReminders() async {
        for index in 0..<3 {
            let center = PausableNotificationCenter()
            let (engine, _) = makeEngine(center: center)
            center.failOffsets = [offsets[index]]
            let result = await engine.start()
            XCTAssertEqual(result.outcome, .started)
            XCTAssertEqual(result.registration.status, .partial, "failure index \(index)")
            XCTAssertEqual(result.registration.failedOffsets, [offsets[index]])
            let succeeded = offsets.enumerated().compactMap { item in item.offset == index ? nil : item.element }
            XCTAssertEqual(result.registration.succeededOffsets, succeeded)
            let message = StartRideDialog.message(
                outcome: result.outcome,
                registration: result.registration,
                notificationsEnabled: true
            )
            XCTAssertTrue(message.contains("部分"))
            XCTAssertFalse(message.contains("将在第 45、50、55 分钟提醒锁车"))
        }

        let center = PausableNotificationCenter()
        let (engine, clock) = makeEngine(center: center)
        center.failOffsets = Set(offsets)
        let failed = await engine.start()
        XCTAssertEqual(failed.registration.status, .failed)
        XCTAssertEqual(failed.registration.failedOffsets, offsets)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(engine.snapshot().session?.registration, .pending)
        let failedMessage = StartRideDialog.message(
            outcome: failed.outcome,
            registration: failed.registration,
            notificationsEnabled: true
        )
        XCTAssertTrue(failedMessage.contains("没有登记成功"))
        XCTAssertFalse(failedMessage.contains("将在第 45、50、55 分钟提醒锁车"))

        center.failOffsets = []
        clock.date = start.addingTimeInterval(46 * 60)
        let repaired = await engine.repair()
        XCTAssertEqual(repaired.status, .full)
        XCTAssertEqual(repaired.addedOffsets, [50 * 60, 55 * 60])
        XCTAssertEqual(center.pending.map(\.offset), [50 * 60, 55 * 60])
        XCTAssertFalse(center.pending.contains { $0.offset == 45 * 60 })
    }

    func testInterruptedStartKeepsOriginalStartAndRestoresFutureReminders() async {
        let center = PausableNotificationCenter()
        let store = MemoryRideStore()
        let (engine, _) = makeEngine(center: center, store: store)
        let session = RideSession(id: UUID(), startedAt: start, endedAt: nil, registration: .pending)
        store.save(session)

        let result = await engine.start()
        XCTAssertEqual(result.outcome, .alreadyActive)
        XCTAssertEqual(result.registration.status, .full)
        XCTAssertEqual(result.registration.succeededOffsets, offsets)
        XCTAssertEqual(engine.snapshot().session?.id, session.id)
        XCTAssertEqual(engine.snapshot().session?.startedAt, start)
        XCTAssertEqual(engine.snapshot().session?.registration, .complete)
        XCTAssertEqual(center.pending.map(\.offset), offsets)
        XCTAssertEqual(center.pending.map(\.fireAt), expectedFires(from: start))

        let message = StartRideDialog.message(
            outcome: result.outcome,
            registration: result.registration,
            notificationsEnabled: true
        )
        XCTAssertTrue(message.contains("未重新计时"))
        XCTAssertTrue(message.contains("已补上尚未发出的锁车提醒"))
    }

    func testRepairUsesFreshClockAndSkipsRemindersThatBecamePastDuringAwait() async {
        let center = PausableNotificationCenter()
        let store = MemoryRideStore()
        let (engine, clock) = makeEngine(center: center, store: store)
        store.save(RideSession(startedAt: start, endedAt: nil, registration: .pending))

        center.pauseBeforeNextPendingRead()
        let repair = Task { await engine.repair() }
        await center.waitUntilPendingReadPaused()
        clock.date = start.addingTimeInterval(46 * 60)
        center.resumePendingRead()
        let result = await repair.value

        XCTAssertEqual(result.addedOffsets, [50 * 60, 55 * 60])
        XCTAssertEqual(center.pending.map(\.offset), [50 * 60, 55 * 60])
        for request in center.pending {
            XCTAssertEqual(request.delay, request.fireAt.timeIntervalSince(clock.date), accuracy: 0.001)
            XCTAssertNotEqual(request.delay, request.offset, accuracy: 0.001)
        }
        XCTAssertFalse(center.pending.contains { $0.fireAt == start.addingTimeInterval(45 * 60) })
    }

    private func expectedFires(from startedAt: Date) -> [Date] {
        offsets.map { startedAt.addingTimeInterval($0) }
    }

    private func makeEngine(
        center: PausableNotificationCenter,
        store: RideStoring = MemoryRideStore()
    ) -> (RideEngine, ManualClock) {
        let clock = ManualClock(date: start)
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("bikeguard-\(UUID().uuidString).lock")
        let engine = RideEngine(store: store, clock: clock, center: center, lockURL: lock)
        return (engine, clock)
    }
}
