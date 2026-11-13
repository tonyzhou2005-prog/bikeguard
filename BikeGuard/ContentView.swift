import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    let engine: RideEngine

    @Environment(\.scenePhase) private var scenePhase
    @State private var banner: String?
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let snapshot = engine.snapshot()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(snapshot)
                        timeCard(snapshot)
                        controls(snapshot)
                        if let banner {
                            Text(banner)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        notificationCard
                        rulesCard
                        shortcutsCard
                    }
                    .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("骑行守卫")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            await prepareNotifications()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshReminders() }
        }
    }

    private func header(_ snapshot: RideSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bicycle")
                .font(.title)
                .foregroundStyle(tint(for: snapshot))
                .frame(width: 52, height: 52)
                .background(tint(for: snapshot).opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("美团单车免费时段")
                    .font(.headline)
                Text(statusTitle(snapshot))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint(for: snapshot))
            }
            Spacer()
        }
    }

    private func timeCard(_ snapshot: RideSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(primaryClock(snapshot))
                .font(.system(size: 68, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel(accessibilityClock(snapshot))
            Text(primaryCaption(snapshot))
                .font(.title3)
                .foregroundStyle(.secondary)
            Divider()
            detailRow("开始时间", value: startText(snapshot))
            detailRow("已骑行", value: elapsedText(snapshot))
            detailRow("免费剩余", value: RideTimeFormat.clock(snapshot.remaining))
            if snapshot.isActive, let startedAt = snapshot.session?.startedAt {
                Text(reminderLine(startedAt: startedAt, now: snapshot.now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func controls(_ snapshot: RideSnapshot) -> some View {
        VStack(spacing: 10) {
            Button {
                switch engine.start() {
                case .started:
                    banner = "已开始。将在第 45、50、55 分钟提醒你确认锁车。"
                    Task { await refreshReminders() }
                case .alreadyActive:
                    banner = "骑行仍在进行，开始时间未重置。"
                }
            } label: {
                Label("开始骑行", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)

            Button {
                if engine.end() {
                    banner = "已结束，尚未发出的锁车提醒已取消。"
                }
            } label: {
                Label("结束骑行", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!snapshot.isActive)
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("通知", systemImage: "bell")
                .font(.headline)
            Text(notificationExplanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(notificationButtonTitle) {
                Task { await handleNotificationButton() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("计时规则")
                .font(.headline)
            Text("美团骑行卡前 60 分钟免费。本应用不连接美团，也不联网，只在这台手机上计时。")
            Text("骑行开始后的 90 分钟内（60 分钟免费时段，再加 30 分钟宽限），再次开始不会重置倒计时，也不会重复安排通知。超过 90 分钟后自动视为本趟已结束。")
            Text("手动结束后，下次开始是新的一趟。")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配合快捷指令")
                .font(.headline)
            Text("在「快捷指令」中新建个人自动化：当「美团」打开时，运行 BikeGuard 的「开始骑行提醒」。请关闭「运行前询问」。")
            Text("不要在「关闭美团」时结束计时。切到别的 App 不代表已经锁车。锁好后，在这里点「结束骑行」，或运行「结束骑行提醒」。")
            Text("请先允许通知。快捷指令可以在不打开本应用界面的情况下开始计时，但系统通知权限需要你打开一次 BikeGuard 来授予。")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func tint(for snapshot: RideSnapshot) -> Color {
        switch snapshot.phase {
        case .riding:
            return Color(red: 0.13, green: 0.55, blue: 0.38)
        case .grace:
            return Color(red: 0.86, green: 0.42, blue: 0.12)
        case .idle, .endedManually, .expiredAutomatically:
            return Color.secondary
        }
    }

    private func statusTitle(_ snapshot: RideSnapshot) -> String {
        switch snapshot.phase {
        case .idle:
            return "未在骑行"
        case .riding:
            return "骑行中"
        case .grace:
            return "已超过免费时段"
        case .endedManually:
            return "已结束"
        case .expiredAutomatically:
            return "上一趟已自动结束"
        }
    }

    private func primaryClock(_ snapshot: RideSnapshot) -> String {
        switch snapshot.phase {
        case .riding(let remaining):
            return RideTimeFormat.clock(remaining)
        case .grace(let overtime):
            return RideTimeFormat.clock(overtime)
        case .idle, .endedManually, .expiredAutomatically:
            return "--:--"
        }
    }

    private func primaryCaption(_ snapshot: RideSnapshot) -> String {
        switch snapshot.phase {
        case .riding:
            return "免费时段剩余"
        case .grace:
            return "已超时，请尽快锁车"
        case .idle:
            return "点开始骑行，或让快捷指令开始"
        case .endedManually:
            return "本趟已结束"
        case .expiredAutomatically:
            return "已超过 90 分钟，下次开始会计新的一趟"
        }
    }

    private func accessibilityClock(_ snapshot: RideSnapshot) -> String {
        switch snapshot.phase {
        case .riding(let remaining):
            return "免费时段剩余 \(RideTimeFormat.spoken(remaining))"
        case .grace(let overtime):
            return "已超时 \(RideTimeFormat.spoken(overtime))"
        case .idle:
            return "未在计时"
        case .endedManually:
            return "本趟已结束"
        case .expiredAutomatically:
            return "上一趟已自动结束"
        }
    }

    private func startText(_ snapshot: RideSnapshot) -> String {
        guard snapshot.isActive, let startedAt = snapshot.session?.startedAt else { return "—" }
        return RideTimeFormat.time.string(from: startedAt)
    }

    private func elapsedText(_ snapshot: RideSnapshot) -> String {
        guard snapshot.isActive, let startedAt = snapshot.session?.startedAt else { return "—" }
        return RideTimeFormat.clock(max(0, snapshot.now.timeIntervalSince(startedAt)))
    }

    private func reminderLine(startedAt: Date, now: Date) -> String {
        let parts = RidePolicy.reminderOffsets.map { offset -> String in
            let fire = startedAt.addingTimeInterval(offset)
            let clock = RideTimeFormat.time.string(from: fire)
            if fire <= now {
                return "\(clock) 已过"
            }
            return clock
        }
        return "锁车提醒：\(parts.joined(separator: "、"))"
    }

    private var notificationExplanation: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return "通知已允许。到点会提醒你确认单车是否锁好。"
        case .denied:
            return "通知未允许，到点不会弹出提醒。请到系统设置里为 BikeGuard 打开通知。"
        case .notDetermined:
            return "需要通知权限，才能在第 45、50、55 分钟提醒锁车。"
        @unknown default:
            return "请检查 BikeGuard 的通知权限。"
        }
    }

    private var notificationButtonTitle: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return "通知已开启"
        case .denied:
            return "前往系统设置"
        case .notDetermined:
            return "允许通知"
        @unknown default:
            return "检查通知权限"
        }
    }

    private func prepareNotifications() async {
        guard !TestRuntime.isUnitTest else { return }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
            authorization = settings.authorizationStatus
        }
        await refreshReminders()
    }

    private func handleNotificationButton() async {
        switch authorization {
        case .denied:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await UIApplication.shared.open(url)
        case .notDetermined:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await refreshReminders()
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }
    }

    private func refreshReminders() async {
        guard !TestRuntime.isUnitTest else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await RideReminderRepair.sync(snapshot: engine.snapshot())
    }
}

enum RideTimeFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func spoken(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return "\(total / 60) 分 \(total % 60) 秒"
    }
}

#Preview {
    ContentView(engine: .shared)
}
