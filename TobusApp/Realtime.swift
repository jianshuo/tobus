import Foundation

/// GTFS-Realtime VehiclePosition 里我们用得到的字段。
struct VehicleSnapshot: Sendable, Equatable {
    var tripID = ""
    var routeID = ""
    var stopID = ""
    var currentStopSequence = 0
    var timestamp: Date = .distantPast
    var latitude = 0.0
    var longitude = 0.0
    var label = ""
}

/// 只认识 FeedMessage → entity → vehicle 这一条路径的极简 protobuf 解码器（免第三方依赖）。
enum GTFSRealtimeDecoder {
    enum DecodeError: Error { case truncated, badWireType }

    struct Reader {
        let bytes: [UInt8]
        var pos: Int
        let end: Int
        init(_ bytes: [UInt8], _ range: Range<Int>? = nil) {
            self.bytes = bytes
            pos = range?.lowerBound ?? 0
            end = range?.upperBound ?? bytes.count
        }
        var atEnd: Bool { pos >= end }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard pos < end else { throw DecodeError.truncated }
                let b = bytes[pos]; pos += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw DecodeError.truncated }
            }
        }
        mutating func fixed32() throws -> UInt32 {
            guard pos + 4 <= end else { throw DecodeError.truncated }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
            pos += 4
            return v
        }
        mutating func lengthDelimited() throws -> Range<Int> {
            let n = Int(try varint())
            guard n >= 0, pos + n <= end else { throw DecodeError.truncated }
            defer { pos += n }
            return pos..<(pos + n)
        }
        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0: _ = try varint()
            case 1: guard pos + 8 <= end else { throw DecodeError.truncated }; pos += 8
            case 2: _ = try lengthDelimited()
            case 5: guard pos + 4 <= end else { throw DecodeError.truncated }; pos += 4
            default: throw DecodeError.badWireType
            }
        }
        /// 依次回调每个字段；回调里若不消费该字段，返回 false 以自动跳过。
        mutating func fields(_ body: (inout Reader, Int, Int) throws -> Bool) throws {
            while !atEnd {
                let key = try varint()
                let field = Int(key >> 3), wire = Int(key & 7)
                if try !body(&self, field, wire) { try skip(wireType: wire) }
            }
        }
        func string(_ r: Range<Int>) -> String { String(decoding: bytes[r], as: UTF8.self) }
    }

    static func decodeVehicles(_ data: Data) throws -> [VehicleSnapshot] {
        let bytes = [UInt8](data)
        var top = Reader(bytes)
        var out: [VehicleSnapshot] = []
        try top.fields { r, field, wire in
            guard field == 2, wire == 2 else { return false }           // FeedMessage.entity
            var entity = Reader(bytes, try r.lengthDelimited())
            try entity.fields { e, f, w in
                guard f == 4, w == 2 else { return false }               // FeedEntity.vehicle
                out.append(try vehicle(bytes, e.lengthDelimited()))
                return true
            }
            return true
        }
        return out
    }

    private static func vehicle(_ bytes: [UInt8], _ range: Range<Int>) throws -> VehicleSnapshot {
        var v = VehicleSnapshot()
        var r = Reader(bytes, range)
        try r.fields { r, f, w in
            switch (f, w) {
            case (1, 2):                                                  // trip: TripDescriptor
                var t = Reader(bytes, try r.lengthDelimited())
                try t.fields { t, f, w in
                    switch (f, w) {
                    case (1, 2): v.tripID = t.string(try t.lengthDelimited())
                    case (5, 2): v.routeID = t.string(try t.lengthDelimited())
                    default: return false
                    }
                    return true
                }
            case (2, 2):                                                  // position: Position
                var p = Reader(bytes, try r.lengthDelimited())
                try p.fields { p, f, w in
                    switch (f, w) {
                    case (1, 5): v.latitude = Double(Float(bitPattern: try p.fixed32()))
                    case (2, 5): v.longitude = Double(Float(bitPattern: try p.fixed32()))
                    default: return false
                    }
                    return true
                }
            case (3, 0): v.currentStopSequence = Int(try r.varint())
            case (5, 0): v.timestamp = Date(timeIntervalSince1970: TimeInterval(try r.varint()))
            case (7, 2): v.stopID = r.string(try r.lengthDelimited())
            case (8, 2):                                                  // vehicle: VehicleDescriptor
                var d = Reader(bytes, try r.lengthDelimited())
                try d.fields { d, f, w in
                    guard f == 2, w == 2 else { return false }
                    v.label = d.string(try d.lengthDelimited())
                    return true
                }
            default: return false
            }
            return true
        }
        return v
    }
}

enum RealtimeFeed {
    /// ODPT 公开端点，无需 key。
    static let url = URL(string: "https://api-public.odpt.org/api/v4/gtfs/realtime/ToeiBus")!

    static func fetchVehicles(routeIDs: Set<String>? = nil) async throws -> [VehicleSnapshot] {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let all = try GTFSRealtimeDecoder.decodeVehicles(data)
        guard let routeIDs else { return all }
        return all.filter { routeIDs.contains($0.routeID) }
    }
}
