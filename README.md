# TimeNote

面向 macOS 的本地项目笔记与时间记录工具，使用 SwiftUI 和 SQLite 开发。

## 功能

- 项目创建、复制、归档与恢复；侧边栏显示每个项目的场记条数与最近记录日期
- 主场记：开始输入时自动锁定时间戳，Enter 提交；按日期分组显示；可编辑、删除（支持撤销）
- 文本标签页，自动保存
- 附件导入（拖入窗口任意位置）、右侧附件面板、在访达中显示
- 全局搜索（中文子串匹配，空格分隔多个关键词）
- 导出 .txt（跨多天时自动加日期分隔）、数据库备份与恢复、窗口置顶

### 快捷键

| 快捷键 | 作用 |
| --- | --- |
| ⌘N | 新建项目 |
| ⌘T | 新建文本标签 |
| ⌘L | 回到主场记输入框 |
| ⌘F | 搜索 |
| ⌘1 … ⌘9 | 切换标签 |
| ⌘E | 导出项目 |
| ⇧⌘C | 复制当前标签全部内容 |
| ⌥⌘A | 显示/隐藏附件面板 |
| ⇧⌘B | 立即备份 |
| ↑ / ↓（输入框内） | 调出最近的输入 |

## 开发环境

- macOS 14 或更高版本
- Swift 6.1 或更高版本（Xcode 16.3+ 或对应的 Command Line Tools）
- 当前打包脚本按 Apple Silicon（arm64）目录取构建结果
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

`scripts/dev_watch.sh` 是一个本地监听脚本：检测到 `.dev/trigger` 变化后执行 build / test / run，并以临时数据启动独立的 "TimeNote Dev" 应用，便于远程协作调试。

## 打包应用

```sh
BUNDLE_NAME=TimeNoteV21 zsh scripts/package_app.sh
```

输出位于 `dist/TimeNoteV21.app` 和 `dist/TimeNoteV21.zip`。脚本默认名称仍为 `TimeNoteV20`，因此打包 V21 时请显式传入上述名称。当前构建使用本地 ad-hoc 签名，未经过 Apple 公证。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `Sources/TimeNoteApp/ContentView.swift` | SwiftUI 界面 |
| `Sources/TimeNoteApp/TimeNoteStore.swift` | 应用状态及交互逻辑 |
| `Sources/TimeNoteApp/SQLiteDatabase.swift` | 数据库、搜索与持久化 |
| `Sources/TimeNoteApp/Models.swift` | 数据模型和时间处理 |
| `Sources/TimeNoteApp/*Service.swift` | 附件、备份恢复、导出及窗口管理 |
| `Tests/TimeNoteAppTests/` | Swift Testing 测试 |
| `scripts/` | 图标生成与应用打包 |
| `docs/` | 历史产品需求与开发方案，仅作背景参考 |

## 数据与备份

应用数据位于 `~/Library/Application Support/TimeNote/`，包括 `timenote.sqlite` 与附件。开发时运行应用也会访问这一目录，修改存储逻辑前请先备份。仓库不包含用户笔记、数据库、附件或本地构建结果。

此仓库源代码来自与 `dist/TimeNoteV21.app` 同级的本地开发目录。现有应用包未提供可核对的源码提交标识，因此不能保证与该二进制逐字节对应。

## 使用 Claude Code 继续开发

克隆仓库后，在项目根目录启动 Claude Code。`CLAUDE.md` 包含架构、验证命令及数据兼容性要求。可以从以下任务开始：

> 先阅读 CLAUDE.md 和 README.md，检查当前实现并运行 swift test，再根据我的需求做小步修改。涉及数据库变更时保持旧数据兼容，并报告验证结果。

## 许可证

[MIT](LICENSE)
