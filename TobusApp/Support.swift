import Foundation
import CoreLocation
import UserNotifications

struct Settings: Codable, Sendable, Equatable {
    var headsign = "東京駅八重洲口"
    var autoNearest = true          // 按当前位置选最近的站
    var stopID: String? = nil       // 定位失败/不在附近时用的默认站（nil = 新川二丁目）
    var notify = true               // 快捷指令触发时同时发通知

    static let key = "settings.v1"
    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Settings.key) }
}

/// 一次性定位，带超时；拿不到就返回 nil（调用方回退到默认站）。
@MainActor
final class LocationOnce: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private static var active: Set<LocationOnce> = []
    private static var permissionManager: CLLocationManager?

    static func get(timeout: TimeInterval) async -> CLLocation? {
        let me = LocationOnce()
        active.insert(me)
        defer { active.remove(me) }
        return await me.run(timeout: timeout)
    }

    static func requestPermission() {
        let m = CLLocationManager()
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        permissionManager = m
    }

    private func run(timeout: TimeInterval) async -> CLLocation? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        if let last = manager.location, last.timestamp.timeIntervalSinceNow > -120 { return last }
        return await withCheckedContinuation { c in
            continuation = c
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(self?.manager.location)
            }
        }
    }

    private func finish(_ loc: CLLocation?) {
        continuation?.resume(returning: loc)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        if continuation != nil, s == .authorizedWhenInUse || s == .authorizedAlways { manager.requestLocation() }
        if continuation != nil, s == .denied || s == .restricted { finish(nil) }
    }
}

enum Notifier {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ board: ArrivalBoard) async {
        let c = UNMutableNotificationContent()
        c.title = "🚌 \(board.stopTitle) → \(board.headsign)"
        c.body = board.summary() + (board.realtimeOK ? "" : "\n（实时数据暂不可用，按时刻表）")
        c.sound = .default
        let req = UNNotificationRequest(identifier: "bus-board", content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
