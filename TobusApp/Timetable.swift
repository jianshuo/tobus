import Foundation
import CoreLocation

/// 内置时刻表（由 scripts/build_data.py 从都营巴士官方 GTFS 生成）。
struct TimetableData: Decodable, Sendable {
    struct Stop: Decodable, Sendable { let name: String; let lat: Double; let lon: Double }
    struct Trip: Decodable, Sendable {
        let id: String
        let r: String      // 東15 / 東16
        let s: String      // service_id
        let h: String      // 行先
        let d: Int         // direction_id
        let p: Int         // pattern index
        let seq: [Int]     // stop_sequence
        let t: [Int]       // 各站发车时刻（运营日 0 点起的秒数，JST）
    }
    struct Calendar: Decodable, Sendable { let id: String; let days: [Int]; let start: String; let end: String }
    struct Exception: Decodable, Sendable { let id: String; let date: String; let type: Int }

    let generated: String
    let feedVersion: String
    let defaultStop: String
    let stops: [String: Stop]
    let patterns: [[String]]
    let trips: [Trip]
    let calendar: [Calendar]
    let exceptions: [Exception]
}

enum Tokyo {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    static let calendar: Foundation.Calendar = {
        var c = Foundation.Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()
    static func ymd(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }
    static func midnight(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static func hhmm(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour!, c.minute!)
    }

    /// GTFS 的 calendar_dates 只覆盖近期；超出范围时用祝日表兜底（休日ダイヤ）。
    static let holidays: Set<String> = [
        "20261103", "20261123",
        "20270101", "20270111", "20270211", "20270223", "20270321", "20270322", "20270429",
        "20270503", "20270504", "20270505", "20270719", "20270811", "20270920", "20270923",
        "20271011", "20271103", "20271123",
        "20280101", "20280110", "20280211", "20280223", "20280320", "20280429",
        "20280503", "20280504", "20280505", "20280717", "20280811", "20280918", "20280922",
        "20281009", "20281103", "20281123",
    ]
}

struct ScheduledPass: Sendable, Identifiable {
    let trip: TimetableData.Trip
    let stopIndex: Int          // 目标站在该 trip 里的下标
    let serviceDay: Date        // 运营日 0 点（JST）
    var id: String { trip.id }
    var scheduled: Date { serviceDay.addingTimeInterval(TimeInterval(trip.t[stopIndex])) }
}

final class Timetable: Sendable {
    let data: TimetableData
    private let tripsByID: [String: TimetableData.Trip]

    init(data: TimetableData) {
        self.data = data
        self.tripsByID = Dictionary(uniqueKeysWithValues: data.trips.map { ($0.id, $0) })
    }

    static let shared: Timetable = {
        let url = Bundle.main.url(forResource: "timetable", withExtension: "json")!
        return try! Timetable(json: Data(contentsOf: url))
    }()

    convenience init(json: Data) throws {
        self.init(data: try JSONDecoder().decode(TimetableData.self, from: json))
    }

    func trip(_ id: String) -> TimetableData.Trip? { tripsByID[id] }
    func stopName(_ id: String) -> String { data.stops[id]?.name ?? id }
    /// 两个方向：去东京站（行先=東京駅八重洲口），或回家方向（从东京站发往東京ビッグサイト / 深川車庫前 / 有明一丁目…，都经过新川）。
    static let toTokyo = "東京駅八重洲口"
    static let fromTokyo = "回家方向"
    var headsigns: [String] { [Timetable.toTokyo, Timetable.fromTokyo] }
    func matches(_ t: TimetableData.Trip, _ direction: String) -> Bool {
        direction == Timetable.fromTokyo ? t.h != Timetable.toTokyo : t.h == direction
    }

    /// 某天开行的 service_id 集合。
    func activeServices(on date: Date) -> Set<String> {
        let ymd = Tokyo.ymd(date)
        let weekday = Tokyo.calendar.component(.weekday, from: date) // 1=Sun
        let idx = (weekday + 5) % 7                                  // 0=Mon ... 6=Sun
        let todays = data.exceptions.filter { $0.date == ymd }
        func base(_ dayIdx: Int) -> Set<String> {
            let inRange = Set(data.calendar.filter { $0.days[dayIdx] == 1 && $0.start <= ymd && ymd <= $0.end }.map(\.id))
            return inRange.isEmpty ? Set(data.calendar.filter { $0.days[dayIdx] == 1 }.map(\.id)) : inRange
        }
        if todays.isEmpty && Tokyo.holidays.contains(ymd) { return base(6) } // 祝日 → 休日ダイヤ
        var set = base(idx)
        for e in todays { if e.type == 1 { set.insert(e.id) } else { set.remove(e.id) } }
        return set
    }

    /// 当天用哪套时刻：都营 service_id 末三位 10x=休日、16x=土曜、17x=平日。
    func dayType(on date: Date) -> String {
        let ids = activeServices(on: date).filter { $0.hasPrefix("81-") }
        let holiday = Tokyo.holidays.contains(Tokyo.ymd(date)) ? "（祝日）" : ""
        if ids.contains(where: { $0.hasPrefix("81-10") }) { return "休日时刻" + holiday }
        if ids.contains(where: { $0.hasPrefix("81-16") }) { return "土曜时刻" }
        if ids.contains(where: { $0.hasPrefix("81-17") }) { return "平日时刻" }
        return "时刻未知"
    }

    /// 某方向（可限定线路）可上车的站（终点站除外）。
    func stopIDs(headsign: String, route: String? = nil) -> Set<String> {
        var ids = Set<String>()
        for t in data.trips where matches(t, headsign) && (route == nil || t.r == route) {
            ids.formUnion(data.patterns[t.p].dropLast())
        }
        return ids
    }

    /// 某方向的终点站（取最常见的末站）。
    func terminal(headsign: String) -> String? {
        var count: [String: Int] = [:]
        for t in data.trips where matches(t, headsign) { if let l = data.patterns[t.p].last { count[l, default: 0] += 1 } }
        return count.max { $0.value < $1.value }?.key
    }

    /// 自动判断：在家附近（800m 内）→ 去东京站；否则 → 回家。
    func autoDirection(at loc: CLLocation, home: CLLocation) -> String {
        loc.distance(from: home) <= 800 ? Timetable.toTokyo : Timetable.fromTokyo
    }

    func location(of stopID: String) -> CLLocation? {
        data.stops[stopID].map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
    }

    func nearestStop(to location: CLLocation, headsign: String, route: String? = nil) -> (id: String, meters: Double)? {
        stopIDs(headsign: headsign, route: route).compactMap { id -> (String, Double)? in
            guard let s = data.stops[id] else { return nil }
            return (id, location.distance(from: CLLocation(latitude: s.lat, longitude: s.lon)))
        }.min { $0.1 < $1.1 }.map { (id: $0.0, meters: $0.1) }
    }

    /// 经过 stopID、往 headsign 方向、计划时刻落在 [from, to] 的班次（含前一运营日跨零点的）。
    func passes(stopID: String, headsign: String, from: Date, to: Date) -> [ScheduledPass] {
        var result: [ScheduledPass] = []
        let today = Tokyo.midnight(from)
        for day in [Tokyo.calendar.date(byAdding: .day, value: -1, to: today)!, today] {
            let services = activeServices(on: day)
            for trip in data.trips where matches(trip, headsign) && services.contains(trip.s) {
                let pat = data.patterns[trip.p]
                guard let i = pat.firstIndex(of: stopID), i < pat.count - 1 else { continue }
                let pass = ScheduledPass(trip: trip, stopIndex: i, serviceDay: day)
                if pass.scheduled >= from && pass.scheduled <= to { result.append(pass) }
            }
        }
        return result.sorted { $0.scheduled < $1.scheduled }
    }
}
