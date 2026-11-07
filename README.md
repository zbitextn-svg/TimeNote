# TimeNote

面向 macOS 的本地项目笔记与时间记录工具，使用 SwiftUI 和 SQLite 开发。

## 功能

- 项目创建、复制、归档与恢复；侧边栏显示每个项目的场记条数与最近记录日期
- 主场记：开始输入时自动锁定时间戳，Enter 提交；按日期分组显示；可编辑、删除（支持撤销）
- 文本标签页，自动保存；标签右上角 × 可删除
- **录音与实时转写**（macOS 26）：一边录音一边在本机转成文字（普通话、粤语、English），录音不上传；
  录音期间记下的场记可一键从对应位置回放；转写的句子可插入为场记；录音时没来得及转写的会在停止后自动补转写；
  可选择输入设备（USB 话筒、声卡、耳机麦克风）；应用异常退出时录音会在下次启动时恢复
- 附件导入（拖入窗口任意位置）、附件弹出面板、在访达中显示
- 全局搜索（中文子串匹配，空格分隔多个关键词），包括录音转写的文字
- 导出：文本（.txt）、Excel 场记单（.xlsx）、PDF 场记单（A4 排版）、**完整资料包**（.zip，含场记单、录音文字和原始录音）；
  录音文字会附在各种导出格式中
- 数据库备份与恢复、窗口置顶

### 快捷键

| 快捷键 | 作用 |
| --- | --- |
| ⌘N | 新建项目 |
| ⌘T | 新建文本标签 |
| ⌘L | 回到主场记输入框 |
| ⌘F | 搜索 |
| ⌘1 … ⌘9 | 切换标签 |
| ⌘E | 导出项目（选择格式） |
| ⇧⌘R | 开始 / 停止录音 |
| ⌥⌘R | 显示 / 隐藏录音面板 |
| ⌥空格（录音面板） | 播放 / 暂停 |
| ⇧⌘C | 复制当前标签全部内容 |
| ⌥⌘A | 显示/隐藏附件面板 |
| ⇧⌘B | 立即备份 |
| ↑ / ↓（输入框内） | 调出最近的输入 |

## 开发环境

- 运行：macOS 26 或更高版本（录音转写依赖 macOS 26 的 SpeechAnalyzer；安装包通过 `LSMinimumSystemVersion` 限制）
- 编译目标仍为 macOS 14（`Package.swift`）：用命令行工具以 macOS 26 为编译目标时，编出的程序会在主线程执行器检查处崩溃；
  语音相关代码用 `@available(macOS 26.0, *)` 隔离
- Swift 6.1 或更高版本（Xcode 16.3+ 或对应的 Command Line Tools）
- 无第三方 Swift 包依赖，使用系统 SQLite 3

在仓库根目录执行：

```sh
swift build
swift test
swift run TimeNoteApp
```

也可以通过 Xcode 打开 `Package.swift`。

### 使用临时数据开发

设置环境变量 `TIMENOTE_DATA_DIR` 后，应用会把数据库和附件放在该目录，而不是 `~/Library/Application Support/TimeNote/`：

```sh
TIMENOTE_DATA_DIR=/tmp/timenote-dev swift run TimeNoteApp
```

DEBUG 构建中再加上 `TIMENOTE_DEMO_SEED=1`，会在空数据库里写入一组演示数据。测试中的 `TimeNoteStore` 均使用临时目录，不会读写真实数据。

`scripts/dev_watch.sh` 是一个本地监听脚本：检测到 `.dev/trigger` 变化后执行 build / test / run 等步骤，并以临时数据启动独立的 "TimeNote Dev" 应用（通过 `open` 启动，麦克风权限记在 TimeNote Dev 名下），便于远程协作调试。

### 录音开发注意事项

- 没有麦克风的 Mac（如 Mac Studio、Mac mini）上，`AVAudioEngine` 安装 tap 会抛出 Objective-C 异常并闪退，因此开始录音前必须先确认有输入设备（`AudioInputDevices`）。
- 音频线程（tap 回调）里不要创建 `@MainActor` 的 `Task` 或切换到主线程刷新界面，实测会导致主线程执行器检查崩溃；电平由主线程每 0.1 秒读取。
- 使用 `SpeechTranscriber` 前要先 `AssetInventory.reserve(locale:)`，否则模型状态一直是「supported」而不是「installed」，转写不会开始。
- 开发版每次重新编译签名都会变化，系统会再次询问麦克风权限。

## 打包应用

当前版本：**V1.2.0**（`Sources/TimeNoteApp/AppInfo.swift`，侧边栏左下角也会显示）。

```sh
zsh scripts/package_app.sh
```

输出位于 `dist/TimeNoteV1.2.0.app` 和 `dist/TimeNoteV1.2.0.zip`。安装包要求 macOS 26，并包含麦克风与语音识别的权限说明。可用 `APP_VERSION`、`BUNDLE_NAME` 环境变量覆盖；修改版本时请同时更新 `AppInfo.swift`。当前构建使用本地 ad-hoc 签名，未经过 Apple 公证。

只安装了命令行工具（没有 Xcode）时，较新的 SDK 中 SwiftUI 依赖宏插件，可能需要指定较旧的 SDK，例如 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk zsh scripts/package_app.sh`。

## 应用图标

图标源文件在 `design/`：`AppIcon.svg` 为标准版，`AppIcon-small.svg` 为 16 / 32 px 的简化版（线条更粗、细节更少，保证小尺寸清晰）。`Sources/TimeNoteApp/Assets.xcassets/AppIcon.appiconset/` 中的 PNG 由它们导出，修改图标时请同时更新这两处。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `Sources/TimeNoteApp/ContentView.swift` | SwiftUI 界面 |
| `Sources/TimeNoteApp/RecordingViews.swift` | 录音按钮、录音面板、转写文字与播放器 |
| `Sources/TimeNoteApp/TimeNoteStore.swift` | 应用状态及交互逻辑 |
| `Sources/TimeNoteApp/TimeNoteStore+Recording.swift` | 录音、转写、回放的状态与流程 |
| `Sources/TimeNoteApp/RecordingService.swift` | 麦克风采集、输入设备、录音文件整理与恢复 |
| `Sources/TimeNoteApp/LiveTranscriber.swift` | 本机语音转写（实时与文件） |
| `Sources/TimeNoteApp/ReportExport.swift` | Excel / PDF 场记单与完整资料包（zip） |
| `Sources/TimeNoteApp/SQLiteDatabase.swift` | 数据库、搜索与持久化 |
| `Sources/TimeNoteApp/Models.swift` | 数据模型和时间处理 |
| `Sources/TimeNoteApp/*Service.swift` | 附件、备份恢复、导出及窗口管理 |
| `Tests/TimeNoteAppTests/` | Swift Testing 测试 |
| `scripts/` | 应用打包与开发监听脚本 |
| `design/` | 应用图标源文件（SVG） |
| `docs/` | 历史产品需求与开发方案，仅作背景参考 |

## 数据与备份

应用数据位于 `~/Library/Application Support/TimeNote/`，包括 `timenote.sqlite`、附件与录音（`attachments/<项目>/recordings/`）。V1.2 只新增了 `recordings`、`transcript_segments` 两张表，旧数据库打开时自动补建，原有数据不变。开发时运行应用也会访问这一目录，修改存储逻辑前请先备份。仓库不包含用户笔记、数据库、附件或本地构建结果。

此仓库源代码来自与 `dist/TimeNoteV21.app` 同级的本地开发目录。现有应用包未提供可核对的源码提交标识，因此不能保证与该二进制逐字节对应。

## 使用 Claude Code 继续开发

克隆仓库后，在项目根目录启动 Claude Code。`CLAUDE.md` 包含架构、验证命令及数据兼容性要求。可以从以下任务开始：

> 先阅读 CLAUDE.md 和 README.md，检查当前实现并运行 swift test，再根据我的需求做小步修改。涉及数据库变更时保持旧数据兼容，并报告验证结果。

## 许可证

[MIT](LICENSE)
