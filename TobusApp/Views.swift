import SwiftUI

@main
struct TobusApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private let routeColors: [String: Color] = [
    "東16": Color(red: 0xC8 / 255, green: 0x82 / 255, blue: 0x43 / 255),
    "東15": Color(red: 0xB8 / 255, green: 0xAD / 255, blue: 0xD4 / 255),
]

struct RouteBadge: View {
    let route: String
    var body: some View {
        Text(route).font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(routeColors[route] ?? .gray, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ArrivalRow: View {
    let a: Arrival
    let now: Date
    var showStop = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            RouteBadge(route: a.route)
            VStack(alignment: .leading, spacing: 2) {
                Text(Tokyo.hhmm(a.expected)).font(.title3.monospacedDigit().bold())
                Group {
                    let stop = (showStop ? "\(a.stopName) · " : "") +
                        (a.homeArrival.map { "\(Tokyo.hhmm($0)) 到\(a.homeStopName) · " } ?? "")
                    if a.isRealtime {
                        let delay = a.delayMinutes
                        Text(stop + "实时 · 时刻表 \(Tokyo.hhmm(a.scheduled))" + (delay > 0 ? " · 晚\(delay)分" : "") +
                             (a.stopsAway.map { " · 还有\($0)站" } ?? ""))
                    } else {
                        Text(stop + "时刻表")
                    }
                }.font(.caption).foregroundStyle(a.isRealtime ? .green : .secondary)
            }
            Spacer()
            let m = a.minutesUntil(now)
            Text(m == 0 ? "即将到" : "\(m) 分").font(.title2.monospacedDigit().bold())
        }
    }
}

struct StopLine: View {
    let stop: RouteStop
    var body: some View {
        HStack(spacing: 6) {
            RouteBadge(route: stop.route)
            Text(stop.stopName).font(.subheadline.bold()).foregroundStyle(.primary)
            Text(stop.distanceMeters.map { "离你 \(Int($0)) 米" } ?? "默认站").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// App Intent 弹出的卡片。
struct BoardSnippet: View {
    let board: ArrivalBoard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(board.directionLabel) · \(Timetable.shared.dayType(on: board.generatedAt))").font(.headline)
            ForEach(board.stops, id: \.self) { StopLine(stop: $0) }
            ForEach(board.next(4)) { ArrivalRow(a: $0, now: board.generatedAt, showStop: !board.sameStop) }
            if board.arrivals.isEmpty { Text("今日已无车").foregroundStyle(.secondary) }
            if !board.realtimeOK { Text("实时数据暂不可用，按时刻表显示").font(.caption2).foregroundStyle(.secondary) }
        }.padding()
    }
}

@MainActor
@Observable
final class BoardModel {
    var board: ArrivalBoard?
    var loading = false
    var settings = Settings.load() { didSet { settings.save() } }

    func refresh() async {
        loading = true
        board = await BusService.loadBoard()
        loading = false
    }
}

struct ContentView: View {
    @State private var model = BoardModel()
    @State private var showSetup = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                List {
                    if let b = model.board {
                        Section {
                            let list = b.arrivals.filter { $0.expected >= ctx.date.addingTimeInterval(-30) }.prefix(8)
                            if list.isEmpty { Text("東16、東15 今日已无车").foregroundStyle(.secondary) }
                            ForEach(Array(list)) { ArrivalRow(a: $0, now: ctx.date, showStop: !b.sameStop) }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("今天：\(Timetable.shared.dayType(on: ctx.date)) · \(b.directionLabel)")
                                    .font(.subheadline.bold()).foregroundStyle(.orange)
                                ForEach(b.stops, id: \.self) { StopLine(stop: $0) }
                            }.textCase(nil)
                        }
                        Text(b.directionLabel + (b.modeNote.isEmpty ? "" : "（\(b.modeNote)）") + " · " +
                             (b.realtimeOK ? "实时位置校正" : "实时不可用，仅时刻表（\(b.realtimeError ?? "")）") +
                             " · 更新于 \(Tokyo.hhmm(b.generatedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    settingsSection
                    Section {
                        Button("设置「离开家里 Wi‑Fi 自动弹出」") { showSetup = true }
                    }
                }
                .refreshable { await model.refresh() }
            }
            .navigationTitle("出门巴士")
            .sheet(isPresented: $showSetup) { SetupGuide() }
        }
        .task {
            LocationOnce.requestPermission()
            await model.refresh()
        }
        .task(id: phase) {
            // 前台时每 30 秒刷新实时数据
            while phase == .active && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await model.refresh()
            }
        }
    }

    private var settingsSection: some View {
        Section("设置") {
            Picker("方向", selection: $model.settings.mode) {
                Text("自动（在家附近→去东京站，否则→回家）").tag("auto")
                Text("去东京站").tag("toTokyo")
                Text("回家").tag("home")
            }
            Toggle("自动选最近的站", isOn: $model.settings.autoNearest)
            Picker("家附近的站", selection: Binding(
                get: { model.settings.stopID ?? Timetable.shared.data.defaultStop },
                set: { model.settings.stopID = $0 })) {
                ForEach(stopsForHeadsign, id: \.self) { Text(Timetable.shared.stopName($0)).tag($0) }
            }
            Toggle("弹出时同时发通知", isOn: $model.settings.notify)
        }
        .onChange(of: model.settings) { old, new in
            Task {
                if new.notify && !old.notify { await Notifier.requestPermission() }
                await model.refresh()
            }
        }
    }

    private var stopsForHeadsign: [String] {
        // 按线路顺序排列
        let tt = Timetable.shared
        let ids = tt.stopIDs(headsign: Timetable.toTokyo)
        var seen = Set<String>(), ordered: [String] = []
        for t in tt.data.trips where tt.matches(t, Timetable.toTokyo) {
            for s in tt.data.patterns[t.p] where ids.contains(s) && seen.insert(s).inserted { ordered.append(s) }
        }
        return ordered
    }
}

struct SetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("一次性设置（约 1 分钟）") {
                    Label("打开「快捷指令」App → 底部「自动化」→ 右上角「+」", systemImage: "1.circle")
                    Label("选「无线局域网」→ 点「网络」选家里的 Wi‑Fi，只勾「离开」", systemImage: "2.circle")
                    Label("选「立即运行」，并关掉「运行时通知」", systemImage: "3.circle")
                    Label("下一步搜索「出门巴士」→ 选「出门看巴士」→ 完成", systemImage: "4.circle")
                }
                Section {
                    Text("之后每次手机断开家里 Wi‑Fi，就会自动弹出通知：离你最近的东16、东15 下两班到站时间。有车辆实时位置时按实际晚点校正，否则按时刻表。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("也可以直接对 Siri 说「出门巴士 下一班」。").font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    Button("打开快捷指令") {
                        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
                    }
                }
                Section("数据来源") {
                    Text("时刻表：都营巴士 GTFS（ODPT 公共交通开放数据），与新川二丁目站牌核对一致。\n实时：ODPT 都营巴士 GTFS‑Realtime 车辆位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("离家自动弹出")
            .toolbar { Button("完成") { dismiss() } }
            .task { await Notifier.requestPermission() }
        }
    }
}
