# BikeGuard（骑行守卫）

美团共享单车的骑行卡通常包含前 **60 分钟免费**。人骑完容易忘了锁车，超时后开始扣费。BikeGuard 是一个完全离线的 iOS 应用：它在本机倒计时，并在开始后的第 **45、50、55** 分钟用系统本地通知提醒你确认单车是否已经锁好。

它不登录美团，不调用美团的任何接口，不读取账号，也不联网。

界面文字为简体中文。许可证：[MIT](LICENSE)。

## 功能

- 开始计时、结束计时、查看免费时段剩余时间。
- 开始时向系统登记 3 条本地通知（第 45、50、55 分钟）。通知由 iOS 投递，不要求应用保持打开。
- 结束骑行时取消尚未发出的通知。
- 快捷指令：`开始骑行提醒`、`结束骑行提醒`。两个 Intent 都设置了 `openAppWhenRun = false`，可以在不打开应用界面的情况下改计时、登记或取消通知。
- 状态保存在本机 `UserDefaults`。应用被关掉或划掉之后，再打开仍能恢复同一趟的开始时间。
- 骑行尚未结束时再次「开始」不会重置倒计时，也不会再排一套重复通知。

## 计时规则

| 时刻 | 状态 | 再次「开始骑行提醒」 |
| --- | --- | --- |
| 尚未开始，或上一趟已手动结束 | 未在骑行 / 已结束 | 开始新的一趟，开始时间是现在 |
| 开始后 0–60 分钟 | 骑行中，显示剩余时间 | **不重置**。保留原来的开始时间，不重新登记通知 |
| 开始后 60–90 分钟 | 已超过免费时段（宽限） | **仍然不重置**。这 30 分钟用来避免你超时后刚打开美团就被当成新的一趟 |
| 开始后满 90 分钟仍未手动结束 | 自动视为已结束 | 开始新的一趟 |

手动点「结束骑行」或运行「结束骑行提醒」会立刻结束，并取消未发出的提醒。结束后哪怕还在原来的 60 分钟里，下一次开始也是新的一趟。

通知文案示例：已骑行 45 分钟，免费时段还剩 15 分钟，请确认单车是否已锁好。

应用回到前台时，如果这趟还有效、但有的提醒因为当时没有通知权限没能登记上，会按**原来的开始时间**把缺的那几条补上（同一条通知使用固定标识，不会叠成两份）。

没有使用 App Group。未签名安装包用免费 Apple ID 重签名时，App Group 一类的 entitlement 经常因为描述文件里没有对应能力而导致安装失败。主应用和 App Intent 在同一个应用包里，用标准 `UserDefaults` 就能共享这一趟的状态。

## 项目结构

```
BikeGuard.xcodeproj          Xcode 工程与共享 scheme（含单元测试）
BikeGuard/
  BikeGuardApp.swift         入口、前台也显示通知
  ContentView.swift          简体中文界面
  Ride/RidePolicy.swift      纯规则：开始、幂等、剩余时间、过期、45/50/55
  Ride/RideStore.swift       内存存储与 UserDefaults 存储
  Ride/RideEngine.swift      可注入时钟的状态机，带跨进程文件锁
  Ride/SystemReminderScheduler.swift
  Intents/RideIntents.swift  「开始骑行提醒」「结束骑行提醒」
  Assets.xcassets
  PrivacyInfo.xcprivacy      UserDefaults 的隐私清单（原因码 CA92.1）
BikeGuardTests/RideLogicTests.swift
.github/workflows/ios.yml
```

部署目标 iOS 17.0。Bundle ID：`io.github.tonyzhou2005.bikeguard`。如果签名时提示标识符已被占用，在 Xcode 的 Signing 里改成你自己的，或改工程里的 `PRODUCT_BUNDLE_IDENTIFIER`。

核心类型可以不启动界面来测：`RidePolicy` 是纯函数，`RideEngine` 接收 `RideClock`、`RideStoring` 和 `RideReminderScheduling`。

## 快捷指令：打开美团时开始提醒

先在 iPhone 上安装 BikeGuard，打开一次，并允许通知。通知权限只能由应用弹出系统对话框；快捷指令在后台运行时要不到这个权限。

然后在「快捷指令」里做个人自动化（按钮名称会随 iOS 版本略有差别，路径是下面这一条）：

1. 打开「快捷指令」。
2. 点底部「自动化」。
3. 点右上角「+」，选择新建个人自动化。
4. 触发条件选「App」。
5. 点「选取」，搜索并勾选「美团」，完成。
6. 勾选「打开时」。不要勾选「关闭时」。
7. 下一步。
8. 添加操作，搜索「开始骑行提醒」或「BikeGuard」。
9. 选中 BikeGuard 提供的「开始骑行提醒」。
10. 下一步。
11. 关闭「运行前询问」。系统若再问一次，选「不询问」。
12. 如果有「运行时通知」，也关掉。否则每次打开美团都会再弹一条快捷指令自己的通知。锁车提醒由 BikeGuard 在第 45、50、55 分钟发出。
13. 完成。

这样，打开美团就会运行「开始骑行提醒」：

- 没有进行中的骑行：从现在起算 60 分钟，并登记 3 条通知。
- 已经在计时（含免费时段结束后的 30 分钟宽限）：什么都不改，开始时间保持第一次的。

结束不要绑在「关闭美团」上。切去别的应用不代表车已经锁了。锁好之后：

- 打开 BikeGuard，点「结束骑行」；或
- 在快捷指令里运行「结束骑行提醒」（也可以把它放到主屏幕）。

若快捷指令列表里暂时看不到这两个动作：先手动打开一次 BikeGuard，回到快捷指令，下拉刷新或搜索 BikeGuard。

## 没有 Mac 时怎么安装

持续集成会产出一个**未签名**的 `BikeGuard-unsigned.ipa`（`Payload/BikeGuard.app` 打成 zip，归档时关闭了代码签名）。可以用下面任一方式装到自己的 iPhone。

### AltStore、SideStore 或 Sideloadly（免费 Apple ID）

1. 打开本仓库的 GitHub Actions，进入最近一次成功的 “iOS” 运行。
2. 在 Artifacts 里下载 `BikeGuard-unsigned-ipa`。
3. 用 [AltStore](https://altstore.io/)、[SideStore](https://sidestore.io/) 或 [Sideloadly](https://sideloadly.io/) 安装这个 ipa。
4. 用你自己的免费 Apple ID 重新签名。这些工具会换成你的证书和描述文件，不需要付费开发者账号，也不需要 Mac 上的 Xcode（Sideloadly 需要一台电脑；AltStore / SideStore 可以在装好配套组件后从手机侧更新）。

免费 Apple ID 签名的应用大约 **7 天后失效**，需要用同一工具重新签名安装。Apple 对免费账号还有应用数量限制（通常同时只能有少数几个用这种方式安装的应用）。

SideStore 需要配对文件或本地网络刷新；AltStore 需要 AltServer。具体以各工具当前的说明为准。

### 以后用 TestFlight（付费开发者账号）

有 Apple Developer Program（付费）之后，可以用 Xcode 或 Transporter 上传归档，再走 TestFlight。那样不需要每 7 天重签。本仓库的 CI **没有** Apple 证书，也不会上传 TestFlight。工程里已经关掉了出口合规加密询问（`ITSAppUsesNonExemptEncryption = NO`），方便以后你自己上传。

在 Mac 上直接开发：用 Xcode 16 或更新版本打开 `BikeGuard.xcodeproj`，选自己的 Team 后运行到模拟器或真机即可。CI 用 `CODE_SIGNING_ALLOWED=NO`，不代表你本机不能签名。

## 持续集成

工作流：`.github/workflows/ios.yml`，名字是 “iOS”。

- 运行器：`macos-26`（当前 GitHub 托管的 macOS 26 镜像；`macos-latest` 也指向它）。
- Xcode：显式切到 `/Applications/Xcode_26.6.app`（该镜像上的默认稳定版，不是 Xcode 27 测试版）。
- 用 `xcodebuild test` 在一台可用的 iPhone 模拟器上编译并跑单元测试，`CODE_SIGNING_ALLOWED=NO`，不需要证书或 Apple ID。
- 用 `xcodebuild archive` 对 `generic/platform=iOS` 打 Release 归档，同样关闭签名，再把 `Payload/BikeGuard.app` 打成 `BikeGuard-unsigned.ipa`。
- 产物：
  - `unit-test-results`：`TestResults.xcresult` 和 `xcodebuild-test.log`
  - `BikeGuard-unsigned-ipa`：未签名 ipa

推送到任意分支，或打开 pull request，都会跑。同一分支上新的推送会取消还在跑的上一次。

## 测试范围

### 已在 CI 里验证

模拟器上的编译，以及 `BikeGuardTests` 里这些 XCTest（见 `BikeGuardTests/RideLogicTests.swift`）：

`RidePolicyTests`

- `testFreeWindowGraceAndReminderConstants`
- `testStartOnIdleSchedules45_50_55`
- `testRestartWhileRidingIsNoOp`
- `testRestartDuringGraceIsNoOp`
- `testRestartAfterGraceStartsNewRide`
- `testRestartAfterManualEndStartsNewRide`
- `testRemainingTimeSamples`
- `testRemainingTimeIsZeroWhenIdleEndedOrPastWindow`
- `testPhaseTransitionsThroughExpiry`
- `testEndOnlyWhileActive`
- `testSessionJSONRoundTrip`

`RideEngineTests`

- `testStartPersistsAndSchedulesOnce`
- `testIdempotentRestartKeepsOriginalStartAndDoesNotReschedule`
- `testEndCancelsRemindersAndPersists`
- `testEndWhenInactiveIsNoOp`
- `testEndDuringGraceStillCancels`
- `testNewStartAfterEndOrExpirySchedulesFreshReminders`
- `testRemainingTimeFollowsInjectedClock`
- `testUserDefaultsRoundTripRestoresRemainingTime`
- `testCorruptPersistenceIsTreatedAsNoRide`
- `testMemoryStoreRoundTripAcrossEngines`

这些测试覆盖：开始、进行中再次开始（含宽限期）不改开始时间且不重复登记通知、结束、剩余时间、满 60 分钟进入宽限、满 90 分钟自动结束、JSON / `UserDefaults` / 内存存储的往返，以及通知偏移正好是 45、50、55 分钟。

CI 还验证了：工程能编过，并且能打出未签名 ipa。具体哪一次运行是绿的，以 GitHub Actions 页面为准。

### 写了但没有在真机上验证

这台持续集成没有 iPhone，也没有登录 iCloud / 快捷指令。下面这些只是按系统 API 实现的，**没有在真机上看过结果**：

- 通知横幅是否真的在第 45、50、55 分钟出现（专注模式、通知摘要、系统省电都可能拦住）。
- 快捷指令 App 里是否列出「开始骑行提醒」「结束骑行提醒」。
- 「打开美团 → 运行开始骑行提醒」这条个人自动化是否触发。
- `openAppWhenRun = false` 时，不打开界面能否成功写入 `UserDefaults` 并叫系统登记通知。
- 应用被系统杀掉之后，已经登记的通知是否仍会响（这是本地通知的正常行为，但没在设备上确认）。
- 用 AltStore / SideStore / Sideloadly 重签名之后能否安装、Intent 是否还在。

装到手机上之后，建议先在应用里点一次「开始骑行」，把系统时间理解成「45 分钟后会响」之前，用 Xcode 控制台或把开始时间改短来做一次真机确认。当前单元测试注入的是假时钟，不会把真通知排到 45 分钟之后再等。

## English

BikeGuard is an offline iOS timer for the 60-minute free window on a Meituan bike pass. It schedules local notifications at 45, 50, and 55 minutes, exposes Shortcuts intents (`开始骑行提醒` / `结束骑行提醒`) that do not reset an in-progress ride, and persists state in UserDefaults. CI on `macos-26` with Xcode 26.6 builds the app, runs the unit tests, and uploads an unsigned IPA. UI copy is Simplified Chinese. See the sections above for the automation steps and for what was not verified on a device.
