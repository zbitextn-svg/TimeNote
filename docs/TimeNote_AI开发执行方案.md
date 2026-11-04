# TimeNote AI 开发执行方案

## 1. 结论先行

如果你后续主要用 AI 来开发，我建议你采用这条路线：

1. 先做一个可稳定使用的 `v1`
2. 技术栈优先选择 `SwiftUI + 局部 AppKit + SQLite + GRDB`
3. 数据库先使用单连接写入模式，降低并发和损坏风险
4. 开发顺序按“主流程优先”推进，不要一开始就把搜索和附件做深

我的推荐版本划分如下：

### 1.1 v1 必做
- 项目管理：新建、切换、复制、删除、归档
- 主场记快速录入
- 主场记编辑与时间重排
- 自定义标签页：新建、重命名、删除、排序
- 自动保存
- 崩溃恢复
- 当前标签复制
- 项目导出 `.txt`
- macOS 深色模式跟随系统
- 窗口置顶

### 1.2 v1.1 再做
- 全局全文搜索
- 图片/音频/视频附件
- 搜索结果高亮与片段预览
- 附件预览体验优化

原因很简单：
- 你的核心价值是“现场快速记事”
- 搜索和附件重要，但不是第一天就决定产品成败的主流程
- 如果先把主场记链路做稳，AI 开发时返工会少很多

---

## 2. 技术选型建议

## 2.1 推荐技术栈
- UI：`SwiftUI`
- macOS 特性桥接：`AppKit`
- 本地数据库：`SQLite`
- Swift 数据访问层：`GRDB`
- 状态管理：轻量 `MVVM`，不要上过重框架
- 附件管理：本地文件系统 + 数据库存路径
- 搜索：`SQLite FTS5`

## 2.2 为什么这样选

### SwiftUI 负责大部分界面
适合快速搭建：
- 左侧项目栏
- 顶部标题区
- 主记录列表
- 底部标签栏
- 搜索结果页

它和 macOS 原生风格也比较一致，后续做深色模式、列表、分栏窗口都比较顺手。

### AppKit 负责 SwiftUI 不够顺手的部分
建议只在这些点上桥接：
- 富一点的文本编辑体验
- 文件选择与导出面板
- 窗口置顶
- 焦点控制和部分键盘行为

这是因为 Apple 官方文档明确支持 SwiftUI 与 AppKit 混合使用，你可以把 AppKit 视图嵌入 SwiftUI，也可以反向托管 SwiftUI 视图。[AppKit integration](https://developer.apple.com/documentation/swiftui/appkit-integration)。

### SQLite 作为本地核心存储
你的产品很适合 SQLite：
- 数据是强结构化的
- 本地优先
- 需要稳定自动保存
- 需要后续做全文搜索
- 需要导出与恢复

### GRDB 比直接手写 sqlite3 更适合 AI 开发
我推荐 `GRDB` 的原因不是“更炫”，而是它更适合 AI 分模块产出：
- 有清晰的迁移机制
- 有稳定的数据访问封装
- 支持全文搜索
- 支持数据库变更观察

GRDB 文档里明确提供了 `Migrations`、`Full-Text Search` 和 `Database Changes Observation` 能力【见参考资料】。

## 2.3 不建议的方案

### 不建议首版用 SwiftData
原因：
- 你的需求明确需要 SQLite 层面的控制
- 你要做 WAL、恢复、FTS、备份策略
- SwiftData 对这些需求不够直接

### 不建议首版用 Electron / Tauri
原因：
- 你当前明确主要跑在 macOS
- 你需要更强的原生感、窗口能力、输入体验和系统集成
- 这类方案更适合跨平台，不是你现在最优先的目标

### 不建议一开始就上复杂架构
不建议上：
- TCA
- CQRS
- 过度事件总线
- 多数据库抽象层

对 AI 开发来说，越直接的架构越稳定。

---

## 3. 推荐工程结构

建议采用这个目录结构：

```text
TimeNote/
  App/
    TimeNoteApp.swift
    AppCoordinator.swift
  Features/
    Projects/
    MainLog/
    Tabs/
    Search/
    Attachments/
    Export/
    Settings/
  Components/
  Data/
    Database/
    Repositories/
    Models/
    Migrations/
  Services/
    FileStorage/
    ExportService/
    BackupService/
    RecoveryService/
    WindowService/
  Utilities/
  Resources/
  Tests/
```

说明：
- `Features/` 按功能拆，方便 AI 一块块实现
- `Data/` 只负责数据模型、数据库和仓储
- `Services/` 放导出、附件、恢复、置顶等系统能力
- `Components/` 放可复用 UI 组件

---

## 4. 架构建议

## 4.1 架构风格
推荐：
- `SwiftUI View`
- `ViewModel`
- `Repository`
- `Database / Service`

不要把业务逻辑写进 View。

## 4.2 数据流建议
- View 负责展示和用户输入
- ViewModel 负责交互状态和调用用例
- Repository 负责数据库读写
- Service 负责文件、导出、备份、恢复等跨模块能力

## 4.3 AI 开发时的拆分原则
- 一个 Prompt 只做一个模块
- 一个模块只改一层主要逻辑
- 每次改完都要求 AI 执行 build 或测试
- 每次改动都要求 AI 给出“影响文件清单”

---

## 5. 数据库方案

## 5.1 数据库引擎建议
推荐使用：
- `SQLite`
- `WAL` 模式
- 单一共享数据库实例
- 首版优先 `DatabaseQueue`

这里我建议你首版优先用 `GRDB.DatabaseQueue`，而不是 `DatabasePool`。

原因：
- GRDB 文档明确写了：如果不确定，优先选 `DatabaseQueue`
- `DatabaseQueue` 使用单数据库连接并串行化访问
- 对你这种单用户桌面工具来说，已经足够
- 这样更容易控制一致性、自动保存和崩溃恢复

官方文档里，GRDB 对 `DatabaseQueue` 的说明是“串行化数据库访问”；而对于 `DatabasePool`，虽然支持并发读，但复杂度也更高【见参考资料】。

## 5.2 为什么首版不追求多连接并发
因为你现在最重要的是：
- 不丢数据
- 不写坏数据
- 输入快
- 恢复稳

不是把数据库并发性能榨到极限。

## 5.3 关于 WAL 的一个重要提醒
SQLite 官方在 `2026-03-13` 修复了一个 WAL 相关的低概率损坏问题，影响场景主要是“同一数据库存在两个或更多连接，并且并发写入或 checkpoint”。

这对你是个提醒：
- 首版尽量坚持单数据库连接
- 不要在多个连接上同时写
- 如果后续升级为多连接模式，确认运行时 SQLite 版本足够新

这不是说不能用 WAL，而是说你现在这类产品，更适合“单连接 + WAL + 顺序写入”的稳妥方案。

---

## 6. 推荐数据模型

## 6.1 projects

```sql
CREATE TABLE projects (
  id TEXT PRIMARY KEY NOT NULL,
  title TEXT NOT NULL,
  is_archived INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT
);
```

说明：
- `id` 用 UUID
- `title` 可编辑
- 默认项目列表按 `created_at DESC`

## 6.2 tabs

```sql
CREATE TABLE tabs (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  sort_index INTEGER NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

说明：
- `kind` 取值建议为：`main_log` / `text`
- `[主场记]` 对应 `main_log`
- 自定义标签页对应 `text`
- `body` 仅自定义标签页使用

## 6.3 log_entries

```sql
CREATE TABLE log_entries (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  tab_id TEXT NOT NULL REFERENCES tabs(id) ON DELETE CASCADE,
  recorded_at TEXT NOT NULL,
  note_text TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

说明：
- `recorded_at` 建议存 ISO 8601 时间戳，不要只存 `HH:mm:ss`
- UI 显示时再格式化成 `HH:mm:ss`
- 这样排序更稳，也方便将来跨天扩展

## 6.4 attachments

```sql
CREATE TABLE attachments (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  tab_id TEXT REFERENCES tabs(id) ON DELETE CASCADE,
  log_entry_id TEXT REFERENCES log_entries(id) ON DELETE CASCADE,
  file_kind TEXT NOT NULL,
  original_name TEXT NOT NULL,
  stored_name TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  mime_type TEXT,
  file_size_bytes INTEGER,
  created_at TEXT NOT NULL
);
```

说明：
- 附件原文件不要直接塞进 SQLite
- 只存元数据和相对路径
- 文件实际放在 App Support 或项目附件目录中

## 6.5 app_meta

```sql
CREATE TABLE app_meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

用途：
- 存储 schema version
- 最近一次恢复状态
- 最近一次备份时间

---

## 7. 搜索设计

## 7.1 搜索建议不要一开始就写成很多张 FTS 表
为了方便 AI 开发，我更建议你用一张统一搜索文档表。

```sql
CREATE TABLE search_documents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type TEXT NOT NULL,
  source_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  tab_id TEXT,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  extra TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);
```

然后基于它创建一张 FTS5 虚表：

```sql
CREATE VIRTUAL TABLE search_documents_fts USING fts5(
  title,
  body,
  extra,
  content='search_documents',
  content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
```

## 7.2 为什么这样设计
- 统一项目标题、标签标题、主场记文本、附件文件名的搜索入口
- 对 AI 来说比维护多套 FTS 触发器更容易
- 后续做搜索结果列表和跳转也更简单

## 7.3 同步策略
首版建议用“应用层同步”：
- 新增项目时，写入一条 search document
- 修改标签时，更新对应 search document
- 新增/编辑主场记时，更新 search document
- 添加附件时，写入附件文件名到 search document

不要首版就把全部同步逻辑放进 SQL trigger。

## 7.4 搜索结果展示建议
- 显示所属项目名
- 显示所属标签名
- 显示命中类型
- 显示片段预览

SQLite FTS5 官方提供 `highlight()` 和 `snippet()`，后续可以直接用于高亮和片段抽取【见参考资料】。

---

## 8. 文件与附件存储

## 8.1 推荐目录

```text
~/Library/Application Support/TimeNote/
  timenote.sqlite
  backups/
  attachments/
    {project-id}/
      {attachment-id}-{sanitized-name}
```

## 8.2 为什么放 App Support
- 符合 macOS 应用数据存放习惯
- 不污染用户桌面和文稿目录
- 更适合自动备份和恢复

## 8.3 附件导入建议
- 使用 `NSOpenPanel`
- 复制文件到应用自己的附件目录
- 数据库里只存相对路径

不要只保存原始绝对路径，否则用户移动原文件后很容易失效。

## 8.4 导出建议
- 文本导出使用 `NSSavePanel`
- 默认文件名为项目标题
- 导出编码固定为 `UTF-8`

---

## 9. 自动保存、恢复与备份

## 9.1 自动保存策略
- 主场记 `Enter` 提交后立即写库
- 编辑记录完成后立即写库
- 自定义标签页在停止输入短暂时间后自动写库
- 项目标题修改后立即写库

## 9.2 恢复策略
- App 启动时先做数据库可用性检查
- 检查正常则直接进入上次状态
- 检查失败则提示恢复
- 若主库损坏，则尝试最近一次备份恢复

## 9.3 备份策略
建议采用轻量本地备份：
- 应用启动时判断是否需要备份
- 每隔固定时间生成一次数据库副本
- 保留最近 `5` 到 `10` 份

首版先做“数据库文件备份”就够了，不要一开始做复杂版本管理。

## 9.4 checkpoint 建议
如果启用 WAL：
- 使用默认自动 checkpoint 先跑起来
- 只有当你确认 WAL 文件过大或性能异常时，再做手动 checkpoint 优化

不要在首版过早优化 checkpoint 策略。

---

## 10. UI 实现建议

## 10.1 主界面布局
- 左侧：项目列表
- 右侧顶部：项目标题 + 操作按钮
- 右侧中部：当前标签内容区
- 右侧底部：标签栏
- 主场记标签额外有底部输入框

## 10.2 主场记输入框
这是全产品最关键的控件，建议优先打磨：
- 默认持续保持焦点
- `Enter` 提交
- 空文本不提交
- 提交后立即清空
- 提交成功后不要让焦点丢失

## 10.3 主场记列表
- 记录行支持自动换行
- 时间戳左侧固定宽度
- 编辑后若发生重排，要自动滚到新位置并短暂高亮
- 数据量大时优先保证滚动稳定性

## 10.4 标签栏
- `[主场记]` 固定第一个
- 自定义标签支持重命名、删除、拖拽排序
- 切换项目后总是回到 `[主场记]`

## 10.5 搜索页
建议用单独搜索面板或右上角全局搜索入口，不要一开始把搜索和主输入框混在一起。

## 10.6 置顶模式
这一块建议交给 AppKit 窗口管理能力处理，不要在 SwiftUI 层硬做。

---

## 11. 开发优先级与分阶段计划

## 11.1 第 0 阶段：脚手架与数据库基础
目标：
- 新建 macOS App
- 建立工程结构
- 接入 GRDB
- 创建数据库与 migration
- 跑通项目、标签、主场记三张核心表

完成标志：
- App 启动时能初始化数据库
- 能插入一条测试项目和一条测试记录

## 11.2 第 1 阶段：主场记 MVP
目标：
- 左侧项目列表
- 右侧主场记界面
- Enter 快速录入
- 自动保存
- 编辑记录
- 修改时间后自动排序

完成标志：
- 可以真实连续录入几十条记录而不卡

## 11.3 第 2 阶段：项目与标签管理
目标：
- 新建项目
- 删除、复制、归档项目
- 新建、重命名、删除、排序标签
- 切换项目默认回到 `[主场记]`

完成标志：
- 多项目和多标签切换稳定

## 11.4 第 3 阶段：复制、导出与恢复
目标：
- 当前标签复制
- `.txt` 导出
- 导出失败提示
- 启动恢复与备份流程

完成标志：
- 崩溃重启后能恢复最近一次自动保存状态

## 11.5 第 4 阶段：全文搜索
目标：
- 建立 search_documents
- 建立 FTS5
- 全局搜索
- 搜索结果跳转

完成标志：
- 可以搜到项目名、标签名、记录文本、附件名

## 11.6 第 5 阶段：附件
目标：
- 导入图片/音频/视频
- 存储到本地附件目录
- 列表中展示附件
- 调用系统能力打开或预览

完成标志：
- 附件移动后不丢失
- 数据库删除记录时附件关系正确

## 11.7 第 6 阶段：打磨与发布前检查
目标：
- 深色模式
- 置顶模式
- 错误提示统一
- 大数据量滚动与编辑测试
- 打包、签名、发布准备

---

## 12. AI 开发时建议的工作方式

## 12.1 一次只让 AI 做一件事
坏例子：
- “帮我把整个 TimeNote 全部做完”

好例子：
- “先实现 GRDB 数据层和 migration”
- “只实现主场记列表与底部输入框，不要碰附件”
- “只实现项目复制和归档，不改 UI 样式”

## 12.2 每次都要求 AI 输出这 4 项
- 改动了哪些文件
- 为什么这样设计
- 如何验证
- 还有哪些风险未覆盖

## 12.3 每个阶段都让 AI 先 build 再继续
建议要求：
- 编译通过
- 无明显警告
- 核心交互可手动验证

## 12.4 不要一开始让 AI 优化架构
先要它把功能跑起来，再逐步抽象。

---

## 13. 可以直接复制给 AI 的 Prompt

## 13.1 脚手架 Prompt

```text
请为一个 macOS 原生应用 TimeNote 搭建开发脚手架，技术栈使用 SwiftUI + GRDB。要求：
1. 创建清晰的目录结构，包含 App、Features、Data、Services、Components、Tests。
2. 接入 SQLite 数据库，并使用 GRDB DatabaseQueue。
3. 创建 migration，初始化 projects、tabs、log_entries、attachments、app_meta 表。
4. 提供 DatabaseManager、基础 Repository 协议和实现。
5. 不要实现附件和搜索 UI。
6. 代码应可编译，并说明每个文件的职责。
```

## 13.2 主场记 Prompt

```text
请在现有 TimeNote macOS 工程中实现主场记 MVP，要求：
1. 左侧显示项目列表，右侧显示当前项目的主场记页面。
2. 底部有输入框，按 Enter 后写入一条记录。
3. 自动使用当前本地时间，存入数据库，界面显示 HH:mm:ss。
4. 提交成功后输入框清空并保持焦点。
5. 空文本按 Enter 不应生成记录。
6. 记录列表支持点击编辑。
7. 修改时间戳后自动按时间排序，并滚动定位到新位置。
8. 保持代码结构清晰，不实现附件和搜索。
9. 完成后请说明如何手动验证。
```

## 13.3 项目与标签管理 Prompt

```text
请在 TimeNote 中实现项目与标签管理，要求：
1. 支持新建、复制、删除、归档项目。
2. 支持新建、重命名、删除、排序自定义标签。
3. 主场记标签固定存在，不可删除、不可重命名。
4. 切换项目后默认回到主场记标签。
5. 所有修改自动保存到 SQLite。
6. 保持 UI 为 macOS 原生风格。
7. 输出变更文件和验证步骤。
```

## 13.4 搜索 Prompt

```text
请为 TimeNote 实现全局全文搜索能力，要求：
1. 使用 SQLite FTS5。
2. 建立统一的 search_documents 表和对应 FTS5 虚表。
3. 搜索范围覆盖项目标题、标签标题、主场记记录文本、自定义标签文本、附件文件名。
4. 提供搜索结果列表，显示命中项目、标签和简短片段。
5. 点击结果后可跳转到对应内容。
6. 不做 OCR、音频转文字和视频识别。
7. 完成后说明数据库同步策略。
```

## 13.5 附件 Prompt

```text
请为 TimeNote 实现附件功能，要求：
1. 支持导入图片、音频、视频文件。
2. 使用 NSOpenPanel 选择文件。
3. 将附件复制到应用自己的附件目录中，并在 SQLite 保存元数据和相对路径。
4. 支持在界面中显示附件名称、类型、大小。
5. 支持点击后使用系统默认方式打开或预览。
6. 不要把二进制文件写进 SQLite。
7. 需要考虑删除记录后附件关系的处理方式。
8. 输出验证步骤和已知风险。
```

---

## 14. 你最适合的实际推进顺序

如果是你自己配合 AI 开发，我建议你就按下面这个顺序推进：

1. 先让 AI 搭数据库和工程结构
2. 再让 AI 只做主场记输入链路
3. 跑通后再做项目和标签管理
4. 然后补导出、复制、恢复
5. 最后再做搜索和附件

不要反过来。

对 TimeNote 来说，真正决定成败的不是“能不能搜”，而是：
- 现场录制时能不能稳定录
- Enter 后会不会卡
- 崩溃后会不会丢
- 编辑后会不会乱

---

## 15. 参考资料

以下推荐基于官方或一手文档：

- Apple AppKit 文档：[AppKit](https://developer.apple.com/documentation/appkit)
- Apple SwiftUI / AppKit 混合文档：[AppKit integration](https://developer.apple.com/documentation/swiftui/appkit-integration)
- Apple 打开文件面板文档：[NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)
- Apple 保存文件面板文档：[NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel)
- SQLite WAL 文档：[Write-Ahead Logging](https://www.sqlite.org/wal.html)
- SQLite FTS5 文档：[SQLite FTS5 Extension](https://www.sqlite.org/fts5.html)
- GRDB 文档：[GRDB Reference](https://groue.github.io/GRDB.swift/docs/0.109.0/index.html)

我基于这些资料做出的关键判断是：
- `SwiftUI + AppKit` 混合是合理路线
- `SQLite + WAL` 适合本地桌面记录工具，但首版应避免多连接复杂并发
- `FTS5` 很适合你的全文搜索需求
- `GRDB DatabaseQueue` 比多连接方案更适合你当前阶段的 AI 开发模式
