import Foundation
import UserNotifications

struct RideNotificationRequest: Equatable, Sendable {
    var identifier: String
    var offset: TimeInterval
    var fireAt: Date
    /// Delay passed to the system, computed from a fresh clock reading immediately before add.
    var delay: TimeInterval
    var title: String
    var body: String
}

enum RideNotificationAddError: Error, Equatable, Sendable {
    case rejected(offset: TimeInterval)
}

protocol RideNotificationCenter: AnyObject, Sendable {
    func pendingIdentifiers() async -> Set<String>
    func removePending(identifiers: [String]) async
    func removeDelivered(identifiers: [String]) async
    func add(_ request: RideNotificationRequest) async throws
    func cancelReminders() async
}

extension RideNotificationCenter {
    func cancelReminders() async {
        await removePending(identifiers: RidePolicy.reminderIdentifiers)
    }

    func discardExistingReminders() async {
        let identifiers = RidePolicy.reminderIdentifiers
        await removeDelivered(identifiers: identifiers)
        await removePending(identifiers: identifiers)
    }
}

final class SystemRideNotificationCenter: RideNotificationCenter, @unchecked Sendable {
    func pendingIdentifiers() async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier))
    }

    func removePending(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelReminders() async {
        await removePending(identifiers: RidePolicy.reminderIdentifiers)
    }

    func add(_ request: RideNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = "bikeguard.ride"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: request.delay, repeats: false)
        let notification = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(notification) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
