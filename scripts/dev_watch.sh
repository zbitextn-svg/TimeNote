#!/bin/zsh
# TimeNote 开发监听脚本
#
# 用途：在本机持续运行，检测到 .dev/trigger 文件内容变化后，按其中的指令执行
#   build  -> swift build
#   test   -> swift test
#   run    -> 打包为独立的开发版 .app（TimeNote Dev），用临时数据目录启动
# 例如 trigger 内容为 "42 build test run"（第一个字段是任意的唯一编号）。
#
# 所有数据读写都指向 .dev/data，不会接触 ~/Library/Application Support/TimeNote。
# 结束监听：在终端按 Ctrl+C。

set -u

ROOT_DIR="${0:A:h:h}"
DEV_DIR="$ROOT_DIR/.dev"
DATA_DIR="$DEV_DIR/data"
TRIGGER="$DEV_DIR/trigger"
STATUS="$DEV_DIR/status"
APP_DIR="$DEV_DIR/TimeNote Dev.app"

mkdir -p "$DEV_DIR" "$DATA_DIR" "$DEV_DIR/module-cache"
export TIMENOTE_DATA_DIR="$DATA_DIR"
# 使用项目内独立的模块缓存，避免命令行工具升级后残留的旧缓存导致清单编译失败
export SWIFTPM_MODULECACHE_OVERRIDE="$DEV_DIR/module-cache"
export CLANG_MODULE_CACHE_PATH="$DEV_DIR/module-cache"
# 部分命令行工具安装里残留了旧版（2024 年）的 PackageDescription.private.swiftinterface，
# 编译器会优先读取它，导致 Package.swift 无法编译。这里在 .dev 下准备一份去掉旧私有接口的副本，
# 通过 SWIFTPM_PD_LIBS 让 SwiftPM 使用它；不修改任何系统文件。
prepare_manifest_api() {
  local src="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/pm/ManifestAPI"
  local dst="$DEV_DIR/pm/ManifestAPI"
  [[ -d "$src" ]] || return 0
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -Rp "$src"/. "$dst"/
  local stale=0
  for private_iface in "$dst"/*.swiftmodule/*.private.swiftinterface(N); do
    local public_iface="${private_iface%.private.swiftinterface}.swiftinterface"
    if [[ -f "$public_iface" && "$private_iface" -ot "$public_iface" ]]; then
      rm -f "$private_iface"
      stale=1
    fi
  done
  if [[ $stale -eq 1 ]]; then
    export SWIFTPM_PD_LIBS="$DEV_DIR/pm"
    echo "已绕过命令行工具中过期的 PackageDescription 私有接口（使用 $dst）"
  fi
}
prepare_manifest_api

# 只装了命令行工具（没有 Xcode）时，系统没有 SwiftUI 宏插件；
# 新版 SDK 中 @State 等变成了宏，会编译失败。这里自动选用最新的、SwiftUI 不依赖宏的 SDK。
select_sdk_for_clt() {
  [[ "$(xcode-select -p)" == *CommandLineTools* ]] || return 0
  local sdk_root="/Library/Developer/CommandLineTools/SDKs"
  local sdk
  for sdk in $(ls -d "$sdk_root"/MacOSX[0-9]*.sdk 2>/dev/null | sort -t X -k 2 -V -r); do
    local iface=$(ls "$sdk"/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/*.swiftinterface 2>/dev/null | head -1)
    [[ -n "$iface" ]] || continue
    local core=$(ls "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface 2>/dev/null | head -1)
    if ! grep -q "macro State" "$iface" ${core:+"$core"} 2>/dev/null; then
      export SDKROOT="$sdk"
      echo "仅有命令行工具：使用不依赖 SwiftUI 宏的 SDK $(basename "$sdk")"
      return 0
    fi
  done
}
select_sdk_for_clt

SCRIPT_PATH="${0:A}"
SCRIPT_MTIME="$(stat -f %m "$SCRIPT_PATH")"
cd "$ROOT_DIR"

write_diagnostics() {
  {
    echo "== swift --version"; swift --version 2>&1
    echo "== xcode-select -p"; xcode-select -p 2>&1
    echo "== CLT package"; pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>&1
    echo "== ManifestAPI"
    ls -la /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI 2>&1
    ls -la /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule 2>&1
    echo "== swiftLanguageModes in interface?"
    grep -l "swiftLanguageModes" /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/* 2>&1
    echo "== SDKs"; ls -la /Library/Developer/CommandLineTools/SDKs 2>&1
    echo "== SDKROOT=${SDKROOT:-<default>}"
  } > "$DEV_DIR/diag.log" 2>&1
}

package_dev_app() {
  local bin_path
  bin_path="$(swift build --manifest-cache none --show-bin-path)/TimeNoteApp"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cp -f "$bin_path" "$APP_DIR/Contents/MacOS/TimeNoteApp"
  cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TimeNoteApp</string>
  <key>CFBundleIdentifier</key><string>com.frey.TimeNoteApp.dev</string>
  <key>CFBundleName</key><string>TimeNote Dev</string>
  <key>CFBundleDisplayName</key><string>TimeNote Dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
}

run_dev_app() {
  local appearance="${1:-}"
  pkill -f "TimeNote Dev.app/Contents/MacOS/TimeNoteApp" 2>/dev/null
  sleep 0.5
  package_dev_app || return 1
  # 直接启动可执行文件，以便继承 TIMENOTE_DATA_DIR 等环境变量
  TIMENOTE_DEMO_SEED=1 TIMENOTE_APPEARANCE="$appearance" "$APP_DIR/Contents/MacOS/TimeNoteApp" > "$DEV_DIR/app.log" 2>&1 &
  return 0
}

echo "TimeNote 开发监听已启动：$ROOT_DIR"
echo "临时数据目录：$DATA_DIR"
echo "按 Ctrl+C 结束。"

last="$(cat "$TRIGGER" 2>/dev/null)"
echo "$last" | grep -q . && echo "（已跳过启动前的旧任务：$last）"
while true; do
  # 脚本被更新后自动重新加载
  if [[ "$(stat -f %m "$SCRIPT_PATH")" != "$SCRIPT_MTIME" ]]; then
    echo "检测到监听脚本更新，重新加载…"
    exec zsh "$SCRIPT_PATH"
  fi
  if [[ -f "$TRIGGER" ]]; then
    current="$(cat "$TRIGGER")"
    if [[ "$current" != "$last" ]]; then
      last="$current"
      words=(${=current})
      job_id="${words[1]:-0}"
      echo ""
      echo "[$(date +%H:%M:%S)] 任务 $job_id：${words[2,-1]}"
      echo "running $job_id" > "$STATUS"
      result="done $job_id"
      for step in ${words[2,-1]}; do
        case "$step" in
          diag)
            write_diagnostics
            result="$result diag=0"
            ;;
          clean)
            rm -rf "$ROOT_DIR/.build" "$DEV_DIR/module-cache"
            mkdir -p "$DEV_DIR/module-cache"
            result="$result clean=0"
            ;;
          build)
            swift build --manifest-cache none > "$DEV_DIR/build.log" 2>&1
            code=$?
            result="$result build=$code"
            echo "  build -> $code"
            [[ $code -ne 0 ]] && break
            ;;
          test)
            swift test --manifest-cache none > "$DEV_DIR/test.log" 2>&1
            code=$?
            result="$result test=$code"
            echo "  test -> $code"
            ;;
          run)
            run_dev_app
            code=$?
            result="$result run=$code"
            echo "  run -> $code"
            ;;
          commit)
            # 在本地开发克隆里创建分支并提交（不会推送）；提交说明来自 .dev/commit-msg.txt
            {
              git checkout -B claude/v22-refresh && git add -A && git commit -F "$DEV_DIR/commit-msg.txt" && git log --oneline -3
            } > "$DEV_DIR/commit.log" 2>&1
            code=$?
            result="$result commit=$code"
            echo "  commit -> $code"
            ;;
          run-light|run-dark)
            run_dev_app "${step#run-}"
            code=$?
            result="$result $step=$code"
            echo "  $step -> $code"
            ;;
          stop)
            pkill -f "TimeNote Dev.app/Contents/MacOS/TimeNoteApp" 2>/dev/null
            result="$result stop=0"
            ;;
          reset-data)
            pkill -f "TimeNote Dev.app/Contents/MacOS/TimeNoteApp" 2>/dev/null
            mv "$DATA_DIR" "$DEV_DIR/data-old-$(date +%s)" 2>/dev/null
            mkdir -p "$DATA_DIR"
            result="$result reset-data=0"
            ;;
        esac
      done
      echo "$result" > "$STATUS"
    fi
  fi
  sleep 1
done
