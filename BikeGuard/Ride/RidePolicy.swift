import Foundation

/// Rules for one Meituan free-ride window.
///
/// A ride stays active from `startedAt` until the user ends it, or until
/// `freeWindow + gracePeriod` (90 minutes) has passed. Starting again while
/// it is still active keeps the original start time and does not produce a
/// new notification plan. After that lifetime, the ride is treated as over
/// and the next start begins a new one.
enum RidePolicy {
    /// Minutes covered by the ride pass.
    static let freeWindow: TimeInterval = 60 * 60
    /// Extra time after the free window during which a new start is still ignored.
    static let gracePeriod: TimeInterval = 30 * 60
    /// Local-notification offsets from the start of the ride.
    static let reminderOffsets: [TimeInterval] = [45 * 60, 50 * 60, 55 * 60]

    static var activeLifetime: TimeInterval { freeWindow + gracePeriod }

    static var reminderIdentifiers: [String] {
        reminderOffsets.map { identifier(forOffset: $0) }
    }

    static func identifier(forOffset offset: TimeInterval) -> String {
        "bikeguard.reminder.\(Int(offset / 60))"
    }

    static func isActive(_ session: RideSession?, now: Date) -> Bool {
        guard let session, session.endedAt == nil else { return false }
        return now.timeIntervalSince(session.startedAt) < activeLifetime
    }

    static func phase(of session: RideSession?, now: Date) -> RidePhase {
        guard let session else { return .idle }
        if session.endedAt != nil { return .endedManually }
        let elapsed = now.timeIntervalSince(session.startedAt)
        if elapsed < freeWindow {
            let remaining = min(freeWindow, freeWindow - max(0, elapsed))
            return .riding(remaining: remaining)
        }
        if elapsed < activeLifetime {
            return .grace(overtime: max(0, elapsed - freeWindow))
        }
        return .expiredAutomatically
    }

    static func remainingTime(session: RideSession?, now: Date) -> TimeInterval {
        if case .riding(let remaining) = phase(of: session, now: now) {
            return remaining
        }
        return 0
    }

    static func reminders(forStart startedAt: Date) -> [RideReminderPlan] {
        reminderOffsets.map { offset in
            RideReminderPlan(
                identifier: identifier(forOffset: offset),
                offset: offset,
                fireAt: startedAt.addingTimeInterval(offset),
                title: "该锁车了吗？",
                body: reminderBody(offset: offset)
            )
        }
    }

    static func reminderBody(offset: TimeInterval) -> String {
        let minutes = Int(offset / 60)
        let remain = Int((freeWindow - offset) / 60)
        return "已骑行 \(minutes) 分钟，免费时段还剩 \(remain) 分钟。请确认单车是否已锁好，避免超时扣费。"
    }

    static func decideStart(existing: RideSession?, now: Date) -> StartDecision {
        if isActive(existing, now: now), let existing {
            return StartDecision(outcome: .alreadyActive, session: existing, remindersToSchedule: [])
        }
        let session = RideSession(startedAt: now, endedAt: nil)
        return StartDecision(
            outcome: .started,
            session: session,
            remindersToSchedule: reminders(forStart: now)
        )
    }

    /// Returns the session to persist when the user ends an active ride.
    /// Returns nil when there is nothing to end.
    static func endedSession(existing: RideSession?, now: Date) -> RideSession? {
        guard var session = existing, isActive(existing, now: now) else { return nil }
        session.endedAt = now
        return session
    }
}

struct RideSession: Codable, Equatable {
    var startedAt: Date
    var endedAt: Date?
}

enum RidePhase: Equatable {
    case idle
    case riding(remaining: TimeInterval)
    case grace(overtime: TimeInterval)
    case endedManually
    case expiredAutomatically
}

struct RideReminderPlan: Equatable {
    var identifier: String
    var offset: TimeInterval
    var fireAt: Date
    var title: String
    var body: String
}

enum StartOutcome: Equatable {
    case started
    case alreadyActive
}

struct StartDecision: Equatable {
    var outcome: StartOutcome
    var session: RideSession
    var remindersToSchedule: [RideReminderPlan]
}

struct RideSnapshot: Equatable {
    var session: RideSession?
    var phase: RidePhase
    var now: Date

    var remaining: TimeInterval {
        if case .riding(let remaining) = phase { return remaining }
        return 0
    }

    var isActive: Bool {
        switch phase {
        case .riding, .grace:
            return true
        case .idle, .endedManually, .expiredAutomatically:
            return false
        }
    }
}
