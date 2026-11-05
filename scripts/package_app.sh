#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TimeNoteApp"
# 版本号与 Sources/TimeNoteApp/AppInfo.swift 保持一致
APP_VERSION="${APP_VERSION:-1.1.23}"
# 支持环境变量覆盖，例如: BUNDLE_NAME=TimeNoteV1.1.23 zsh scripts/package_app.sh
BUNDLE_NAME="${BUNDLE_NAME:-TimeNoteV${APP_VERSION}}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$DIST_DIR/$BUNDLE_NAME.zip"
APPICONSET_DIR="$ROOT_DIR/Sources/TimeNoteApp/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP_DIR="$DIST_DIR/AppIcon.iconset"
ICON_PATH="$RESOURCES_DIR/AppIcon.icns"

# 图标 PNG 由 design/AppIcon.svg（16/32 px 用 design/AppIcon-small.svg）导出，提交在仓库中
for icon in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x icon_128x128 icon_128x128@2x icon_256x256 icon_256x256@2x icon_512x512 icon_512x512@2x; do
  if [[ ! -f "$APPICONSET_DIR/$icon.png" ]]; then
    echo "缺少图标文件：$APPICONSET_DIR/$icon.png" >&2
    exit 1
  fi
done
swift build -c release
# 向 SwiftPM 询问实际的构建输出目录（不同 Swift 版本、架构、SDK 下目录名不同，不能写死）
BUILD_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BUILD_DIR/$APP_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "找不到编译产物：$EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

rm -rf "$ICONSET_TMP_DIR"
mkdir -p "$ICONSET_TMP_DIR"
cp "$APPICONSET_DIR"/*.png "$ICONSET_TMP_DIR/"
iconutil -c icns "$ICONSET_TMP_DIR" -o "$ICON_PATH"
rm -rf "$ICONSET_TMP_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>TimeNoteApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.frey.TimeNoteApp</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>${BUNDLE_NAME}</string>
  <key>CFBundleName</key>
  <string>${BUNDLE_NAME}</string>
  <key>CFBundleGetInfoString</key>
  <string>${BUNDLE_NAME} ${APP_VERSION}, Copyright 2026 frey</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright 2026 frey</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Packaged app: $APP_DIR"
echo "Packaged zip: $ZIP_PATH"
echo "Bundle display name: $BUNDLE_NAME"
echo "Version: $APP_VERSION"
