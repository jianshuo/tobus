import Foundation

struct Arrival: Identifiable, Sendable, Hashable {
    let id: String               // trip_id
    let route: String            // 東15 / 東16
    let scheduled: Date          // 时刻表时间
    let expected: Date           // 预测到站（有实时就校正，没有就=时刻表）
    let isRealtime: Bool
    let stopsAway: Int?          // 还差几站（有实时才有）
    let vehicleLabel: String?
    var stopName = ""

    var delayMinutes: Int { Int((expected.timeIntervalSince(scheduled) / 60).rounded()) }
    func minutesUntil(_ now: Date) -> Int { max(0, Int(expected.timeIntervalSince(now) / 60)) }
}

/// 某条线路选中的上车站（每条线路各选离你最近、且该线路会停的站）。
struct RouteStop: Sendable, Hashable {
    let route: String
    let stopID: String
    let stopName: String
    let distanceMeters: Double?
}

struct ArrivalBoard: Sendable {
    let stops: [RouteStop]          // 按 Routes.all 顺序
    let headsign: String
    let arrivals: [Arrival]
    let realtimeOK: Bool
    let generatedAt: Date

    func stop(for route: String) -> RouteStop? { stops.first { $0.route == route } }

    /// 标题用：两条线同站就写一个站名，不同站就分别写。
    var stopTitle: String {
        let names = stops.map(\.stopName)
        return Set(names).count <= 1 ? (names.first ?? "") : stops.map { "\($0.route) \($0.stopName)" }.joined(separator: " / ")
    }

    /// 两条线路混排、按到站时间排序的最近 n 班。
    func next(_ n: Int) -> [Arrival] { Array(arrivals.prefix(n)) }
    var sameStop: Bool { Set(stops.map(\.stopID)).count <= 1 }

    /// 每条线路最近的 n 班。
    func next(_ n: Int, per route: String) -> [Arrival] {
        Array(arrivals.filter { $0.route == route }.prefix(n))
    }
}

enum Routes { static let all = ["東16", "東15"] }

enum ArrivalEngine {
    /// 从「最近经过的站 k」推算晚点：车在 k 与 k+1 之间，取两站计划时刻的中点作为「此刻应在的位置」。
    static func estimateDelay(trip: TimetableData.Trip, serviceDay: Date, vehicle: VehicleSnapshot, timetable: Timetable) -> (delay: TimeInterval, passedIndex: Int)? {
        let idx: Int
        if !vehicle.stopID.isEmpty, let i = timetable.data.patterns[trip.p].firstIndex(of: vehicle.stopID) {
            idx = i
        } else if let i = trip.seq.firstIndex(of: vehicle.currentStopSequence) {
            idx = i
        } else { return nil }
        let a = TimeInterval(trip.t[idx])
        let b = idx + 1 < trip.t.count ? TimeInterval(trip.t[idx + 1]) : a
        let expectedNow = serviceDay.addingTimeInterval((a + b) / 2)
        let delay = max(-60, vehicle.timestamp.timeIntervalSince(expectedNow)) // 很少提前，最多算早 1 分钟
        return (delay, idx)
    }

    /// 两条线路同一个站（测试 / 兜底用）。
    static func board(stopID: String, headsign: String, distance: Double? = nil, now: Date = .now,
                      vehicles: [VehicleSnapshot]?, timetable: Timetable = .shared) -> ArrivalBoard {
        let stops = Routes.all.map { RouteStop(route: $0, stopID: stopID, stopName: timetable.stopName(stopID), distanceMeters: distance) }
        return board(stops: stops, headsign: headsign, now: now, vehicles: vehicles, timetable: timetable)
    }

    static func board(stops: [RouteStop], headsign: String, now: Date = .now,
                      vehicles: [VehicleSnapshot]?, timetable: Timetable = .shared) -> ArrivalBoard {
        let byTrip = Dictionary((vehicles ?? []).map { ($0.tripID, $0) }, uniquingKeysWith: { a, b in a.timestamp > b.timestamp ? a : b })
        var out: [Arrival] = []
        for rs in stops {
            // 往前多看 60 分钟（晚点的车可能还没到），往后看 6 小时（足够判断「今日已无车」）
            let candidates = timetable.passes(stopID: rs.stopID, headsign: headsign,
                                              from: now.addingTimeInterval(-60 * 60), to: now.addingTimeInterval(6 * 3600))
                .filter { $0.trip.r == rs.route }
            for p in candidates {
                if let v = byTrip[p.trip.id], let (delay, passed) = estimateDelay(trip: p.trip, serviceDay: p.serviceDay, vehicle: v, timetable: timetable) {
                    guard passed < p.stopIndex else { continue }                  // 已经开过本站
                    let eta = max(now, p.scheduled.addingTimeInterval(delay))     // 数据有几十秒延迟；ETA 不早于「现在」
                    out.append(Arrival(id: p.trip.id, route: p.trip.r, scheduled: p.scheduled, expected: eta,
                                       isRealtime: true, stopsAway: p.stopIndex - passed, vehicleLabel: v.label, stopName: rs.stopName))
                } else {
                    // 没有实时数据：还没发车或漏报 → 按时刻表；已过点的不显示
                    guard p.scheduled >= now.addingTimeInterval(-30) else { continue }
                    out.append(Arrival(id: p.trip.id, route: p.trip.r, scheduled: p.scheduled, expected: p.scheduled,
                                       isRealtime: false, stopsAway: nil, vehicleLabel: nil, stopName: rs.stopName))
                }
            }
        }
        out.sort { $0.expected < $1.expected }
        return ArrivalBoard(stops: stops, headsign: headsign, arrivals: out, realtimeOK: vehicles != nil, generatedAt: now)
    }
}

/// App 和 App Intent 共用的一站式入口：定位 → 最近站 → 拉实时 → 合成。
enum BusService {
    static func loadBoard(useLocation: Bool = true) async -> ArrivalBoard {
        let settings = Settings.load()
        let tt = Timetable.shared
        let fallbackID = settings.stopID ?? tt.data.defaultStop
        var anchor = tt.location(of: fallbackID)
        var fromGPS = false
        if useLocation && settings.autoNearest, let loc = await LocationOnce.get(timeout: 4),
           let near = tt.nearestStop(to: loc, headsign: settings.headsign), near.meters < 3000 {
            anchor = loc                                // 不在附近（比如人在外地）就以默认站为准
            fromGPS = true
        }
        // 每条线路各找离 anchor 最近、且该线路会停的站：東16 不停南高橋/鉄砲洲 等站
        let stops: [RouteStop] = Routes.all.map { r in
            let near = anchor.flatMap { tt.nearestStop(to: $0, headsign: settings.headsign, route: r) }
            let id = near?.id ?? fallbackID
            return RouteStop(route: r, stopID: id, stopName: tt.stopName(id), distanceMeters: fromGPS ? near?.meters : nil)
        }
        let vehicles = try? await RealtimeFeed.fetchVehicles()
        return ArrivalEngine.board(stops: stops, headsign: settings.headsign, vehicles: vehicles)
    }
}

extension ArrivalBoard {
    /// 通知 / 对话框里的摘要：两条线混排，按到站时间排序。
    func summary(now: Date = .now, count: Int = 4) -> String {
        let list = next(count)
        guard !list.isEmpty else { return "東16、東15 今日已无车" }
        return list.map { x in
            let m = x.minutesUntil(now)
            let at = sameStop ? "" : " @\(x.stopName)"
            let tag = x.isRealtime ? (x.delayMinutes > 0 ? " 晚\(x.delayMinutes)分" : " 实时") : ""
            return "\(x.route) \(m == 0 ? "即将到" : "\(m)分后") \(Tokyo.hhmm(x.expected))\(tag)\(at)"
        }.joined(separator: "\n")
    }
}
