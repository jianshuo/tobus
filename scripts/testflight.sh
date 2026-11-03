#!/bin/bash
# 本地打包并上传 TestFlight（不依赖 fastlane；Xcode 用 ASC API key 自动管理分发签名）。
# 前提：App Store Connect 已有 bundle id = com.wangjianshuo.tobus 的 App 记录，且开发者协议已签。
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID=S6363V64RS
ISSUER=69a6de82-56b6-47e3-e053-5b8c7c11a4d1
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
BUILD_NUM=$(date +%Y%m%d%H%M)
OUT=build/testflight

xcodegen generate -q
rm -rf "$OUT"; mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>97XBW2A43H</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

xcodebuild archive -project Tobus.xcodeproj -scheme Tobus -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Tobus.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" "${AUTH[@]}" -quiet

xcodebuild -exportArchive -archivePath "$OUT/Tobus.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" "${AUTH[@]}"

echo "✅ 已上传 build ${BUILD_NUM}，App Store Connect 处理约 5–15 分钟后出现在 TestFlight。"
