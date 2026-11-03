import AppIntents
import SwiftUI

/// 给「快捷指令 → 自动化 → 离开 Wi‑Fi」调用：弹出最近一班東16/東15 的到站时间。
struct ShowBusTimesIntent: AppIntent {
    static let title: LocalizedStringResource = "出门看巴士"
    static let description = IntentDescription("显示离你最近的东16、东15到站时间（时刻表＋实时位置校正），并发送通知。")
    static let openAppWhenRun = false

    @Parameter(title: "同时发送通知", default: true)
    var sendNotification: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let board = await BusService.loadBoard()
        if sendNotification && Settings.load().notify { await Notifier.post(board) }
        return .result(dialog: IntentDialog(stringLiteral: "\(board.stopTitle)\n" + board.summary()),
                       view: BoardSnippet(board: board))
    }
}

struct TobusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowBusTimesIntent(),
                    phrases: ["\(.applicationName) 下一班", "用\(.applicationName)看巴士", "Next bus in \(.applicationName)"],
                    shortTitle: "出门看巴士",
                    systemImageName: "bus")
    }
}
