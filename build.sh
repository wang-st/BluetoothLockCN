#!/bin/bash
# 蓝牙感应锁 — 编译打包脚本
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="蓝牙感应锁"
BUNDLE_ID="com.local.BluetoothLockCN"
EXEC="BluetoothLockCN"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

echo "==> 编译 ($ARCH)..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O \
  -o "$APP/Contents/MacOS/$EXEC" \
  Sources/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework ServiceManagement \
  -framework CoreBluetooth \
  -framework UserNotifications \
  -framework CoreGraphics \
  -target "${ARCH}-apple-macos13.0"

echo "==> 写入 Info.plist..."
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXEC}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>需要持续访问蓝牙，用于监测您的设备是否在附近，以便在离开时自动锁屏。</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>需要访问蓝牙以连接并监测您的设备信号。</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>用于在设备离开和返回时向您发送提醒。</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

echo "==> 复制图标资源..."
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/LockTemplate.png "$APP/Contents/Resources/LockTemplate.png"

echo "==> Ad-hoc 签名..."
codesign --force -s - "$APP"

echo "==> 完成: $PWD/$APP"
