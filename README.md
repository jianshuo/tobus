# 出门巴士（Tobus）

离开家里 Wi‑Fi 时自动弹出：离你最近的都营巴士 **東16 / 東15**（往 東京駅八重洲口）下两班到站时间。

- **时刻表**：内置都营巴士官方 GTFS（ODPT），已与新川二丁目站牌（0689‑02，東15 2026‑04‑01 改正 / 東16 2025‑03‑31 改正）逐格核对一致；平日 / 土曜 / 休日、祝日自动切换。
- **实时校正**：ODPT 公开 GTFS‑Realtime（`api-public.odpt.org/api/v4/gtfs/realtime/ToeiBus`，无需 key）。车辆报告「最近经过的站」，取该站与下一站计划时刻的中点对比车辆时间戳得到晚点，加到目标站计划时刻上；同时显示「还有 N 站」。没有实时数据的班次按时刻表。
- **最近的站**：按当前定位选 3km 内最近的上车站，定位失败则用默认站（新川二丁目，可改）。

## 离家触发

iOS 不允许 App 在后台监听 Wi‑Fi 断开，所以用系统「快捷指令」自动化：

快捷指令 → 自动化 → ＋ → 无线局域网 → 选家里 Wi‑Fi、只勾「离开」→ 立即运行 → 操作选「出门巴士 › 出门看巴士」。

触发后会发一条通知（下两班 東16、東15 的分钟数、到站时刻、是否晚点）。手动运行或对 Siri 说「出门巴士 下一班」会弹出卡片。

## 开发

```bash
xcodegen generate
xcodebuild test -project Tobus.xcodeproj -scheme Tobus -destination 'platform=iOS Simulator,name=iPhone 17'
```

时刻改正后更新数据：

```bash
curl -L -o /tmp/toei.zip https://api-public.odpt.org/api/v4/files/Toei/data/ToeiBus-GTFS.zip
mkdir -p /tmp/toei && unzip -o /tmp/toei.zip -d /tmp/toei
python3 -I scripts/build_data.py /tmp/toei TobusApp/Resources/timetable.json
```

图标：GPT Image 2（Codex 订阅）生成，源图 `scripts/icon-source.png`。
