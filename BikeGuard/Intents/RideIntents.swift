import AppIntents
import UserNotifications

struct StartRideIntent: AppIntent {
    static var title: LocalizedStringResource = "开始骑行提醒"
    static var description = IntentDescription(
        "开始 60 分钟免费骑行倒计时，并在第 45、50、55 分钟提醒确认锁车。若本趟尚未结束，再次运行不会重置。"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = RideEngine.shared.start()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let dialog: IntentDialog
        switch (outcome, Self.notificationsEnabled(settings.authorizationStatus)) {
        case (.started, true):
            dialog = "已开始骑行提醒。免费时段 60 分钟，将在第 45、50、55 分钟提醒锁车。"
        case (.started, false):
            dialog = "已开始计时，但通知尚未允许。请打开 BikeGuard 并允许通知，否则到点不会提醒。"
        case (.alreadyActive, _):
            dialog = "骑行提醒已在进行中，未重新计时。"
        }
        return .result(dialog: dialog)
    }

    private static func notificationsEnabled(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

struct EndRideIntent: AppIntent {
    static var title: LocalizedStringResource = "结束骑行提醒"
    static var description = IntentDescription("结束当前骑行倒计时，并取消尚未发出的锁车提醒。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: IntentDialog = RideEngine.shared.end()
            ? "已结束骑行提醒，并取消后续锁车通知。"
            : "当前没有进行中的骑行提醒。"
        return .result(dialog: dialog)
    }
}

struct BikeGuardShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRideIntent(),
            phrases: [
                "用\(.applicationName)开始骑行提醒",
                "\(.applicationName)开始骑行提醒"
            ],
            shortTitle: "开始骑行提醒",
            systemImageName: "bicycle"
        )
        AppShortcut(
            intent: EndRideIntent(),
            phrases: [
                "用\(.applicationName)结束骑行提醒",
                "\(.applicationName)结束骑行"
            ],
            shortTitle: "结束骑行提醒",
            systemImageName: "lock.fill"
        )
    }
}
