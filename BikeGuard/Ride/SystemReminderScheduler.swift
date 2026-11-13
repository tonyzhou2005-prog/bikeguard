import Foundation
import UserNotifications

final class SystemReminderScheduler: RideReminderScheduling {
    func replaceReminders(with reminders: [RideReminderPlan]) {
        let center = UNUserNotificationCenter.current()
        let identifiers = RidePolicy.reminderIdentifiers
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        let now = Date()
        for reminder in reminders {
            Self.enqueue(reminder, now: now, center: center)
        }
    }

    func cancelReminders() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: RidePolicy.reminderIdentifiers)
    }

    static func enqueue(_ reminder: RideReminderPlan, now: Date, center: UNUserNotificationCenter) {
        let interval = reminder.fireAt.timeIntervalSince(now)
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = "bikeguard.ride"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.identifier,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}

/// Fills in any reminder that never got scheduled (for example the ride was
/// started before notification permission existed). Same identifiers, so this
/// cannot stack a second copy of a reminder that is already pending.
enum RideReminderRepair {
    static func sync(snapshot: RideSnapshot) async {
        let center = UNUserNotificationCenter.current()
        guard snapshot.isActive, let startedAt = snapshot.session?.startedAt else {
            center.removePendingNotificationRequests(withIdentifiers: RidePolicy.reminderIdentifiers)
            return
        }
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        for reminder in RidePolicy.reminders(forStart: startedAt) where !pendingIDs.contains(reminder.identifier) {
            SystemReminderScheduler.enqueue(reminder, now: snapshot.now, center: center)
        }
    }
}
