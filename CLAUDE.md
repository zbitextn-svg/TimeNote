# TimeNote 开发指引

## 项目

macOS 14+ 原生 SwiftUI 应用；Swift 6.1+（swift-tools-version 6.1）、Swift 6 language mode；Swift Package Manager；系统 SQLite3。优先阅读 README.md 与 Package.swift。

## 架构入口

- TimeNoteApp.swift：应用入口、菜单和通知。
- ContentView.swift：SwiftUI 视图。
- Theme.swift：颜色、圆角、字体等设计 token 与通用小组件。
- AppPaths.swift：数据目录（支持 TIMENOTE_DATA_DIR 覆盖）。
- DemoData.swift：DEBUG 演示数据（TIMENOTE_DEMO_SEED=1）。
- TimeNoteStore.swift：@MainActor 状态与业务协调。
- SQLiteDatabase.swift：表结构、迁移、CRUD、搜索、事务。
- Models.swift：模型及时间处理。
- AttachmentService / RecoveryService / ExportService / WindowService：对应服务。
- Tests/TimeNoteAppTests：使用 Swift Testing。

## 开发流程

1. 先检查当前实现，再围绕用户需求做范围明确的修改。
2. 验证使用 swift build 与 swift test；界面修改还需在 macOS 手动检查。
3. 打包使用 BUNDLE_NAME=TimeNoteV21 zsh scripts/package_app.sh。当前脚本依赖 arm64 输出路径。
4. 不提交 .build、dist、真实用户数据库、附件、备份、凭证或环境文件。
5. 文档 docs/ 是历史背景，可能与当前实现存在差异，不应自动当作待执行任务。

## 数据兼容

应用默认访问 ~/Library/Application Support/TimeNote/，开发运行也可能使用真实数据；开发时请设置 TIMENOTE_DATA_DIR 指向临时目录。测试中的 TimeNoteStore 必须传入临时 rootDirectory。未经用户授权，不删除、重置或迁移其真实数据库。优先使用临时目录进行存储测试。

数据库改动保持旧数据兼容，必要时增加迁移，并覆盖已有数据的读取与升级。保留事务及备份恢复行为。注意日志时间跨日、文本草稿保存和窗口失活时的保存。

## 协作

界面及说明优先使用中文。不要把历史方案中尚未实现的功能写成已完成。提交说明应包含变更目的、验证结果及实际限制。
