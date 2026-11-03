import XCTest
import CoreLocation
@testable import Tobus

final class TobusTests: XCTestCase {
    let tt = Timetable.shared

    private func jst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        Tokyo.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func minutes(route: String, on day: Date, hour: Int) -> [Int] {
        tt.passes(stopID: "0689-02", headsign: "東京駅八重洲口",
                  from: day.addingTimeInterval(TimeInterval(hour * 3600)),
                  to: day.addingTimeInterval(TimeInterval(hour * 3600 + 3599)))
            .filter { $0.trip.r == route && $0.serviceDay == day }
            .map { Tokyo.calendar.component(.minute, from: $0.scheduled) }
    }

    // 与站牌照片（新川二丁目 0689-02）逐格核对
    func testWeekdayMatchesPhoto() {
        let fri = jst(2026, 11, 6) // 周五，平日
        XCTAssertEqual(minutes(route: "東16", on: fri, hour: 8), [4, 7, 13, 17, 22, 26, 33, 39, 45, 51, 58])
        XCTAssertEqual(minutes(route: "東15", on: fri, hour: 7), [18, 39, 59])
        XCTAssertEqual(minutes(route: "東16", on: fri, hour: 21), [3, 23, 43])
    }

    func testSaturdayAndHolidayMatchPhoto() {
        let sat = jst(2026, 11, 7)
        XCTAssertEqual(minutes(route: "東15", on: sat, hour: 7), [20, 45])
        XCTAssertEqual(minutes(route: "東16", on: sat, hour: 9), [6, 18, 26, 32, 43, 54])
        let sun = jst(2026, 11, 8)
        XCTAssertEqual(minutes(route: "東16", on: sun, hour: 12), [7, 16, 20, 33, 46, 59])
        XCTAssertEqual(minutes(route: "東15", on: sun, hour: 21), [0, 48])
    }

    func testHolidayUsesHolidayService() {
        // 2027-01-11 成人の日（周一）超出 calendar_dates 范围 → 按休日ダイヤ
        let s = tt.activeServices(on: jst(2027, 1, 11))
        XCTAssertTrue(s.contains("81-100"))
        XCTAssertFalse(s.contains("81-170"))
        // 2026-11-03 文化の日：GTFS 显式指定
        XCTAssertFalse(tt.activeServices(on: jst(2026, 11, 3)).contains("81-170"))
    }

    func testNearestStop() {
        let near = tt.nearestStop(to: .init(latitude: 35.6747, longitude: 139.7818), headsign: "東京駅八重洲口")
        XCTAssertEqual(near.map { tt.stopName($0.id) }, "新川二丁目")
    }

    // 回归：南高橋只有東15 停。人站在南高橋旁，東16 必须去找它自己停的最近站，而不是报「今日已无车」
    func testNearestStopPerRoute() {
        let here = CLLocation(latitude: 35.67359, longitude: 139.78259) // 南高橋
        let h = "東京駅八重洲口"
        XCTAssertEqual(tt.nearestStop(to: here, headsign: h).map { tt.stopName($0.id) }, "南高橋")
        XCTAssertEqual(tt.nearestStop(to: here, headsign: h, route: "東15").map { tt.stopName($0.id) }, "南高橋")
        let s16 = tt.nearestStop(to: here, headsign: h, route: "東16")!
        XCTAssertEqual(tt.stopName(s16.id), "新川二丁目")

        let noon = jst(2026, 11, 6, 12, 0)
        let stops = ["東16": s16.id, "東15": "1483-01"].map { RouteStop(route: $0.key, stopID: $0.value, stopName: tt.stopName($0.value), distanceMeters: nil) }
        let board = ArrivalEngine.board(stops: stops, headsign: h, now: noon, vehicles: nil)
        XCTAssertFalse(board.next(2, per: "東16").isEmpty)
        XCTAssertFalse(board.next(2, per: "東15").isEmpty)
    }

    func testDecodeRealtimeFixture() throws {
        let url = Bundle(for: Self.self).url(forResource: "toeibus-rt", withExtension: "bin")!
        let v = try GTFSRealtimeDecoder.decodeVehicles(Data(contentsOf: url))
        XCTAssertEqual(v.count, 483)
        XCTAssertEqual(v[0].tripID, "04801-2-85-101-1353")
        XCTAssertEqual(v[0].routeID, "002")
        XCTAssertEqual(v[0].stopID, "2630-02")
        XCTAssertEqual(v[0].currentStopSequence, 2)
        XCTAssertEqual(v[0].timestamp.timeIntervalSince1970, 1793681778)
        XCTAssertEqual(v[0].latitude, 35.6047096, accuracy: 1e-5)
        XCTAssertEqual(v[0].label, "W410")
        XCTAssertEqual(v.filter { ["049", "050"].contains($0.routeID) }.count, 13)
    }

    func testRealtimeCorrection() throws {
        // 取周五 8:26 那班東16，假设车在新川二丁目前 3 站、晚了约 4 分钟
        let fri = jst(2026, 11, 6)
        let p = tt.passes(stopID: "0689-02", headsign: "東京駅八重洲口",
                          from: jst(2026, 11, 6, 8, 26), to: jst(2026, 11, 6, 8, 26))
            .first { $0.trip.r == "東16" }!
        let k = p.stopIndex - 3
        let mid = (Double(p.trip.t[k]) + Double(p.trip.t[k + 1])) / 2
        var v = VehicleSnapshot()
        v.tripID = p.trip.id
        v.stopID = tt.data.patterns[p.trip.p][k]
        v.timestamp = fri.addingTimeInterval(mid + 240)
        let board = ArrivalEngine.board(stopID: "0689-02", headsign: "東京駅八重洲口",
                                        now: v.timestamp, vehicles: [v])
        let a = try XCTUnwrap(board.arrivals.first { $0.id == p.trip.id })
        XCTAssertTrue(a.isRealtime)
        XCTAssertEqual(a.delayMinutes, 4)
        XCTAssertEqual(a.stopsAway, 3)

        // 已经开过本站的车不显示
        v.stopID = tt.data.patterns[p.trip.p][p.stopIndex]
        let board2 = ArrivalEngine.board(stopID: "0689-02", headsign: "東京駅八重洲口", now: v.timestamp, vehicles: [v])
        XCTAssertNil(board2.arrivals.first { $0.id == p.trip.id })
    }
}
