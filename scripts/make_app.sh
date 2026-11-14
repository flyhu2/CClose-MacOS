#!/bin/bash
#
# make_app.sh —— 把 release 二进制打包成 cclose-mac.app（菜单栏应用）
# 产物: dist/cclose-mac.app，双击即可运行，可拖进「登录项」实现开机自启。
#
# 说明: 用 ad-hoc 签名，仅在本机运行，无需开发者账号。
#       签名要求固定绑定 Bundle ID，重新编译后不会因为 CDHash 变化反复丢权限。
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="cclose-mac"
DISPLAY_NAME="CClose-MscOS"
BUNDLE_ID="local.jingzhe.cclose-mac"
VERSION="1.0.1"
BUILD="3"
MODE="${1:-release}"
case "$MODE" in debug|release) ;; *) echo "用法: make_app.sh [release|debug]"; exit 1 ;; esac

BIN="$(pwd)/.build/${MODE}/cclose-mac"
APP="$(pwd)/dist/${APP_NAME}.app"

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "❌ cclose-mac 正在运行。请先从菜单栏退出，再重新打包。"
  echo "   这样可以确保新版真正替换成功，也避免旧实例继续占用手势。"
  exit 1
fi

# 始终让 SwiftPM 做一次增量编译。只判断二进制是否存在会把旧程序继续打进 App，
# 表现为“源码修过了，双击运行却完全没变化”。
echo "==> 编译最新源码"
bash scripts/build.sh "$MODE"
[ -x "${BIN}" ] || { echo "❌ 编译失败"; exit 1; }

echo "==> 组装应用包: ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Assets/Brand/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 flyhu2. MIT License. 交互设计参考 cclose (c) Chaohe Shi.</string>
</dict>
</plist>
PLIST

plutil -lint "${APP}/Contents/Info.plist" >/dev/null

echo "==> ad-hoc 签名（稳定指定要求）"
# 不指定 requirement 时，ad-hoc 签名会退化为“只认 CDHash”。程序一重新编译，
# 辅助功能和输入监控权限就会被 macOS 视为另一个 App。这里让签名要求只绑定
# Bundle ID，后续重建时代码要求保持稳定，权限也就不会反复丢失。
DESIGNATED_REQUIREMENT="designated => identifier \"${BUNDLE_ID}\""
codesign --force --deep --sign - \
  --identifier "${BUNDLE_ID}" \
  -r="${DESIGNATED_REQUIREMENT}" \
  "${APP}" 2>/dev/null || {
  echo "❌ codesign 失败"
  exit 1
}

echo ""
echo "✅ 打包完成: ${APP}"
echo ""
echo "下一步:"
echo "  1) open \"${APP}\"           # 启动后菜单栏出现图标"
echo "  2) 系统设置 → 隐私与安全性：辅助功能、输入监控都要勾选 cclose-mac"
echo "  3) \"${APP}/Contents/MacOS/${APP_NAME}\" --diagnose   # 确认置顶是否可用"
