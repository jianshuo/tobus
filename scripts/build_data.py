#!/usr/bin/env python3
"""从都营巴士官方 GTFS 抽出 東15/東16 的全部班次，生成 App 内置的 timetable.json。

用法：
  curl -L -o /tmp/toei.zip https://api-public.odpt.org/api/v4/files/Toei/data/ToeiBus-GTFS.zip
  mkdir -p /tmp/toei && unzip -o /tmp/toei.zip -d /tmp/toei
  python3 -I scripts/build_data.py /tmp/toei TobusApp/Resources/timetable.json
时刻表改正（ダイヤ改正）后重跑一次、重新编译即可。
"""
import csv, json, sys, datetime

ROUTES = {"東１５": "東15", "東１６": "東16"}

def rd(d, name):
    return csv.DictReader(open(f"{d}/{name}", encoding="utf-8-sig"))

def secs(s):
    h, m, x = map(int, s.split(":"))
    return h * 3600 + m * 60 + x

def main(d, out):
    routes = {r["route_id"]: ROUTES[r["route_short_name"]] for r in rd(d, "routes.txt") if r["route_short_name"] in ROUTES}
    trips = {t["trip_id"]: t for t in rd(d, "trips.txt") if t["route_id"] in routes}
    stop_times = {}
    for r in rd(d, "stop_times.txt"):
        if r["trip_id"] in trips:
            stop_times.setdefault(r["trip_id"], []).append(r)
    services = {trips[t]["service_id"] for t in stop_times}
    calendar = [
        {"id": c["service_id"], "days": [int(c[k]) for k in ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")],
         "start": c["start_date"], "end": c["end_date"]}
        for c in rd(d, "calendar.txt") if c["service_id"] in services]
    exceptions = [{"id": c["service_id"], "date": c["date"], "type": int(c["exception_type"])}
                  for c in rd(d, "calendar_dates.txt") if c["service_id"] in services]

    patterns, pidx, out_trips, used = [], {}, [], set()
    for tid, rows in stop_times.items():
        rows.sort(key=lambda r: int(r["stop_sequence"]))
        seq = tuple(r["stop_id"] for r in rows)
        if seq not in pidx:
            pidx[seq] = len(patterns); patterns.append(list(seq))
        used.update(seq)
        t = trips[tid]
        out_trips.append({"id": tid, "r": routes[t["route_id"]], "s": t["service_id"], "h": t["trip_headsign"],
                          "d": int(t["direction_id"]), "p": pidx[seq],
                          "seq": [int(r["stop_sequence"]) for r in rows],
                          "t": [secs(r["departure_time"]) for r in rows]})
    out_trips.sort(key=lambda x: (x["r"], x["t"][0]))
    stops = {s["stop_id"]: {"name": s["stop_name"], "lat": float(s["stop_lat"]), "lon": float(s["stop_lon"])}
             for s in rd(d, "stops.txt") if s["stop_id"] in used}
    feed = next(rd(d, "feed_info.txt"), {})
    data = {"generated": datetime.date.today().isoformat(), "feedVersion": feed.get("feed_version", ""),
            "defaultStop": "0689-02", "stops": stops, "patterns": patterns, "trips": out_trips,
            "calendar": calendar, "exceptions": exceptions}
    json.dump(data, open(out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"{len(out_trips)} trips, {len(patterns)} patterns, {len(stops)} stops, {len(exceptions)} exceptions -> {out}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
