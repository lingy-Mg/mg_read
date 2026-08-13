# M2：Flutter 应用基础设施

## 状态与范围

M2 按四个必须顺序完成的交付包拆分。本次只实现 **M2.1**；M2.2、M2.3 和 M2.4 仅记录边界和验收条件，不能由本次实现提前触发。

- M2.1：已实现，并通过本次交付的格式、分析、生成和自动化测试验收。
- M2.2–M2.4：未开始。

本阶段不得实现 Node 正式通信、WebSocket/HTTP Runtime Client、ZIP 安装、真实书源、SQLite/Drift、文件提交、下载、设置页或诊断页。

## 依赖决策（M2.1）

| 依赖 | 固定版本 | 用途与维护状态 | 首发平台与包体影响 |
| --- | --- | --- | --- |
| `flutter_riverpod` | `3.4.2` | Riverpod 推荐 `(Async)Notifier` 管理用户交互引起的可变状态；用于显式组合根和可释放状态边界。 | 支持 Android、Windows、macOS；纯 Dart/Flutter 依赖，不引入原生 Runtime。 |
| `go_router` | `17.3.0` | Flutter 官方发布的声明式 Router API 封装；用于路由配置和深链语义。 | 支持 Android、Windows、macOS；纯 Dart 路由层，增加少量发布 Dart 代码。 |
| `go_router_builder` | `4.4.0` | Flutter 官方强类型路由代码生成器；仅开发期使用。 | 不进入发布产物。 |
| `build_runner` | `2.15.1` | 执行路由辅助代码生成；仅开发期使用。当前 Flutter 固定的 `meta 1.18.0` 与 `2.15.2+` 不兼容，因此使用解析器可接受的精确版本。 | 不进入发布产物。 |

这些版本已针对当前 Flutter `3.44.9` / Dart `3.12.2` 核验。正式加入 Drift、SQLite、路径和平台包前，M2.2/M2.3 需重新做当时的官方文档、平台与体积审查。

## M2.1：状态、错误与路由基础

### 目标

- 建立不携带原始异常、正文、URL、Cookie、令牌、数据库记录或堆栈的统一不可变 `AppError`。
- 将架构协议中的稳定错误码映射为可行动的 UI 语义：临时可重试、Runtime 不可用、插件不可用、需要交互、内容不可用、存储压力、不兼容、取消和安全未知错误。
- 在 `main()` 用 `ProviderScope` 建立 Riverpod 组合根；依赖通过明确 Provider 注入并在 scope 销毁时释放资源。
- 只使用不可变 `Notifier`/`AsyncNotifier` 作为会变化的 feature 状态所有者；不用 `ChangeNotifier`、`StateNotifier`、全局业务单例或 Widget 内请求。
- 用 `go_router` 和 `go_router_builder` 声明 `LibraryRoute` 与只携带稳定 `bookId` 的 `ReaderRoute`。路由不传正文、图片、数据源、Repository 或 controller。
- 为页面状态实现初始加载、已有数据刷新、成功内容、成功空态、可重试失败、不可行动失败，并在刷新失败时保留成功数据。
- 每次请求分配单调递增的 generation；旧请求完成、页面 provider 已销毁时不得再写状态。

### M2.1 当前边界

- 默认 `LibraryOverviewLoader` 只返回空的本地投影，用于验证生命周期；它不访问网络、Node、插件、文件或数据库。
- `ReaderRoute` 只表达稳定 ID 的导航意图，显示受控占位内容；不得构造 `ReaderHostPage` 或尝试解析正文。
- 当前错误文案只来自归一化类别；不把上游 `Exception.toString()` 展示或持久化。

### M2.1 验收

1. `ProviderScope` 能驱动 `MaterialApp.router`，Router 在 scope 销毁时释放。
2. 生成的类型化路由能够导航到稳定-ID 阅读意图，而不传可变依赖。
3. 页面初始加载、刷新、保留数据失败和重试都由不可变 `LibraryPageState` 表示。
4. 两个重叠刷新完成时，只有最新 generation 可以更新页面。
5. Widget 测试覆盖加载、已有数据刷新失败保留和类型化路由；单元测试覆盖错误归一化与 generation 保护。

## M2.2：持久化与 Repository

M2.2 在 M2.1 验收后才开始，负责：

- 在 Flutter 受控后台 Isolate 打开唯一 Drift/SQLite 执行器；UI Isolate 不直接打开第二连接。
- 交付 v1 Schema：插件记录与版本、书架、来源绑定、目录快照/条目、阅读进度、书签、下载任务、内容文件、缓存条目、插件小型 KV、设置和脱敏诊断事件。
- 对插件记录、书架、来源绑定、目录、进度、书签、下载任务、内容文件和设置建立领域 Repository；Flutter 数据库保持唯一业务权威。
- 开启 WAL、外键、事务、批处理、迁移和由实际查询证明的必要索引；目录刷新和进度合并不能暴露半完成状态。
- 为 v1 新建、迁移前向 fixture、事务回滚、批处理、关键索引和 Repository 行为补齐测试。

本包不实现 Node 正式通信或下载传输；Node 不能获得数据库路径或 SQL 能力。

## M2.3：文件布局与有界计算

M2.3 在 M2.2 验收后才开始，负责：

- 根据应用支持目录建立 `database/`、`plugins/`、`content/`、`downloads/`、`cache/`、`staging/` 和 `diagnostics/` 的受控布局。
- 临时文件写入、大小/类型/摘要校验、同卷原子重命名、未提交对象的幂等提交窗口和恢复决策接口。
- 数据库仅保存相对 `fileId`，绝不保存平台绝对路径、临时 HTTP URL 或未经编码的插件/远端 ID 路径。
- 定义启动恢复接口：有界扫描 staging/part、检查合法 sidecar/检查点、识别已提交缺失文件和安全期限后的垃圾回收候选。
- 提供固定 worker 数与队列上限的 Flutter 后台 Isolate 计算执行器，包含 deadline、取消、generation、背压和诊断；禁止每任务新建 Isolate。
- 为路径编码、原子提交决策、恢复分支、队列满、取消和旧 generation 补充单元测试。

本包不实现 ZIP 安装、真实网络传输或 Runtime 的 `host.storage.*` handler。

## M2.4：设置与诊断展示骨架

M2.4 在 M2.3 验收后才开始，负责：

- 设置与只读诊断页面骨架及明确入口。
- Runtime、数据库、缓存、恢复摘要、应用/平台/架构等信息的只读 view state；不提供任意 SQL、脚本、URL 或文件路径执行入口。
- 明亮、暗黑和系统主题接入既有语义主题；窄/宽布局保持同一信息层级。
- 键盘、鼠标、触摸焦点、命中区域和语义树测试；必要时在首发平台分别做人工运行验收。

本包只消费后续基础设施公开的脱敏快照，不启动 Node、查询数据库表内容或绕过 Repository。

## M2 总体完成条件

M2 只有在四个包按顺序全部满足以下条件后才完成：公开契约和迁移路径已记录；受影响单元/Widget/Repository/迁移测试通过；格式与静态检查通过；实际运行、Windows/macOS、Android 真机验收按已执行范围分别报告；日志和诊断不包含正文、用户标识、Cookie、令牌或数据库内容。
