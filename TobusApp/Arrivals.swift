import Foundation

struct Arrival: Identifiable, Sendable, Hashable {
    let id: String               // trip_id
    let route: String            // 東15 / 東16
    let scheduled: Date          // 时刻表时间
    let expected: Date           // 预测到站（有实时就校正，没有就=时刻表）
    let isRealtime: Bool
    let stopsAway: Int?          // 还差几站（有实时才有）
    let vehicleLabel: String?

    var delayMinutes: Int { Int((expected.timeIntervalSince(scheduled) / 60).rounded()) }
    func minutesUntil(_ now: Date) -> Int { max(0, Int(expected.timeIntervalSince(now) / 60)) }
}

struct ArrivalBoard: Sendable {
    let stopID: String
    let stopName: String
    let headsign: String
    let distanceMeters: Double?
    let arrivals: [Arrival]
    let realtimeOK: Bool
    let generatedAt: Date

    /// 每条线路最近的 n 班。
    func next(_ n: Int, per route: String) -> [Arrival] {
        Array(arrivals.filter { $0.route == route }.prefix(n))
    }
}

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

    static func board(stopID: String, headsign: String, distance: Double? = nil, now: Date = .now,
                      vehicles: [VehicleSnapshot]?, timetable: Timetable = .shared) -> ArrivalBoard {
        // 往前多看 60 分钟：晚点的车可能还没到
        let candidates = timetable.passes(stopID: stopID, headsign: headsign,
                                          from: now.addingTimeInterval(-60 * 60), to: now.addingTimeInterval(3 * 3600))
        let byTrip = Dictionary((vehicles ?? []).map { ($0.tripID, $0) }, uniquingKeysWith: { a, b in a.timestamp > b.timestamp ? a : b })
        var out: [Arrival] = []
        for p in candidates {
            if let v = byTrip[p.trip.id], let (delay, passed) = estimateDelay(trip: p.trip, serviceDay: p.serviceDay, vehicle: v, timetable: timetable) {
                guard passed < p.stopIndex else { continue }                  // 已经开过本站
                var eta = p.scheduled.addingTimeInterval(delay)
                // 数据有几十秒延迟；ETA 至少不早于「现在」
                if eta < now { eta = now }
                out.append(Arrival(id: p.trip.id, route: p.trip.r, scheduled: p.scheduled, expected: eta,
                                   isRealtime: true, stopsAway: p.stopIndex - passed, vehicleLabel: v.label))
            } else {
                // 没有实时数据：还没发车，或数据缺失 → 按时刻表；已过点的就不显示了
                guard p.scheduled >= now.addingTimeInterval(-30) else { continue }
                // 有实时数据可用、本该已在路上却没出现的车，仍按时刻表展示（可能刚发车/漏报）
                out.append(Arrival(id: p.trip.id, route: p.trip.r, scheduled: p.scheduled, expected: p.scheduled,
                                   isRealtime: false, stopsAway: nil, vehicleLabel: nil))
            }
        }
        out.sort { $0.expected < $1.expected }
        return ArrivalBoard(stopID: stopID, stopName: timetable.stopName(stopID), headsign: headsign,
                            distanceMeters: distance, arrivals: out, realtimeOK: vehicles != nil, generatedAt: now)
    }
}

/// App 和 App Intent 共用的一站式入口：定位 → 最近站 → 拉实时 → 合成。
enum BusService {
    static func loadBoard(useLocation: Bool = true) async -> ArrivalBoard {
        let settings = Settings.load()
        let tt = Timetable.shared
        var stopID = settings.stopID ?? tt.data.defaultStop
        var distance: Double? = nil
        if useLocation && settings.autoNearest, let loc = await LocationOnce.get(timeout: 4),
           let near = tt.nearestStop(to: loc, headsign: settings.headsign),
           near.meters < 3000 {                       // 不在附近（比如人在外地）就用默认站
            stopID = near.id
            distance = near.meters
        }
        let vehicles = try? await RealtimeFeed.fetchVehicles()
        return ArrivalBoard.make(stopID: stopID, headsign: settings.headsign, distance: distance, vehicles: vehicles)
    }
}

extension ArrivalBoard {
    static func make(stopID: String, headsign: String, distance: Double?, vehicles: [VehicleSnapshot]?) -> ArrivalBoard {
        ArrivalEngine.board(stopID: stopID, headsign: headsign, distance: distance, vehicles: vehicles)
    }

    /// 通知 / 对话框里的一句话摘要。
    func summary(now: Date = .now) -> String {
        let parts = ["東16", "東15"].compactMap { r -> String? in
            let a = next(2, per: r)
            guard !a.isEmpty else { return "\(r) 今日已无车" }
            return "\(r) " + a.map { x in
                let m = x.minutesUntil(now)
                let tag = x.isRealtime ? (x.delayMinutes > 0 ? "·晚\(x.delayMinutes)分" : "·实时") : ""
                return "\(m == 0 ? "即将到" : "\(m)分")(\(Tokyo.hhmm(x.expected))\(tag))"
            }.joined(separator: "，")
        }
        return parts.joined(separator: "\n")
    }
}
