# M2：Flutter 主项目 UI 基础设施

## 状态与范围

M2 只建立 `mg_read` 的 UI 基础设施。自 [ADR-0008](../architecture/adr/0008-standalone-plugin-runtime-boundary.md)
接受后，插件 Runtime、平台承载、WS/HTTP、Runtime Store、文件恢复、下载和插件数据
不属于本仓库；它们由 `mg_read_runtime` 独立交付。

- M2.1：已实现的 UI 状态、错误和路由基础。
- M2.2–M2.4：未开始；只记录 UI 消费 Runtime Facade 的边界，不能提前实现 Runtime。
- 本阶段不得实现 Node/Javet、WebSocket/HTTP Runtime Client、`host.*` handler、ZIP
  安装、真实书源、Drift/SQLite Runtime 数据库、文件提交、缓存、下载或平台 Runtime
  适配。

## 依赖决策（M2.1）

| 依赖 | 固定版本 | 用途与维护状态 | 首发平台与包体影响 |
| --- | --- | --- | --- |
| `flutter_riverpod` | `3.4.2` | Riverpod 推荐 `(Async)Notifier` 管理用户交互引起的可变 UI 状态；用于显式组合根和可释放状态边界。 | 支持 Android、Windows、macOS；纯 Dart/Flutter 依赖，不引入 Runtime。 |
| `go_router` | `17.3.0` | Flutter 官方发布的声明式 Router API 封装；用于路由配置和深链语义。 | 支持 Android、Windows、macOS；纯 Dart 路由层，增加少量发布 Dart 代码。 |
| `go_router_builder` | `4.4.0` | Flutter 官方强类型路由代码生成器；仅开发期使用。 | 不进入发布产物。 |
| `build_runner` | `2.15.1` | 执行路由辅助代码生成；仅开发期使用。当前 Flutter 固定的 `meta 1.18.0` 与 `2.15.2+` 不兼容，因此使用解析器可接受的精确版本。 | 不进入发布产物。 |

Runtime 集成包的依赖、版本、原生影响和平台探针由 `mg_read_runtime` 记录。本项目只审阅其
稳定公开门面，不以 Provider、回调或数据库路径注入 Runtime 实现。

## M2.1：状态、错误与路由基础

### 目标

- 建立不携带原始异常、正文、URL、Cookie、令牌、Runtime Store 记录或堆栈的统一不可变 `AppError`。
- 将 Runtime 稳定错误码映射为可行动的 UI 语义：临时可重试、Runtime 不可用、插件不可用、需要交互、内容不可用、存储压力、不兼容、取消和安全未知错误。
- 在 `main()` 用 `ProviderScope` 建立 Riverpod UI 组合根；UI Provider 的生命周期不得被用作 Runtime 生命周期、`HostPort` 或服务注入容器。
- 只使用不可变 `Notifier`/`AsyncNotifier` 作为会变化的 feature 状态所有者；不用 `ChangeNotifier`、`StateNotifier`、全局业务单例或 Widget 内请求。
- 用 `go_router` 和 `go_router_builder` 声明 `LibraryRoute` 与只携带稳定 ID 的 `ReaderRoute`。路由不传正文、图片、数据源、Repository、Runtime 对象或 controller。
- 为页面状态实现初始加载、已有数据刷新、成功内容、成功空态、可重试失败和不可行动失败，并在刷新失败时保留成功数据。

### M2.1 当前边界

- 默认 `LibraryOverviewLoader` 只返回受控空投影，用于验证 UI 生命周期；它不访问网络、Node、插件、文件、Runtime Store 或数据库。
- `ReaderRoute` 只表达稳定 ID 的导航意图，显示受控占位内容；不得构造 Runtime Client 或尝试解析正文。
- 当前错误文案只来自归一化类别；不把上游 `Exception.toString()` 展示或持久化。

## M2.2：Runtime Facade 的 UI 消费

M2.2 在 M2.1 验收后才开始，负责：

- 引用 `mg_read_runtime` 发布的版本化 Flutter-facing Facade，不实现其 transport、启动或持久化。
- 建立 feature application 到 Facade 的窄 UI 端口和强类型投影，覆盖插件中心、书架、发现、详情、下载和诊断的页面状态。
- Runtime 返回的书架、目录、进度、书签、下载和插件状态是唯一数据源；不创建 Drift/SQLite Repository、影子缓存或同步层。
- 通过 Runtime 发布的阅读器 DataSource/StateStore 适配连接 `novel_reader_ui`；不在主项目保存语义进度或读取资源 URL。
- 为 Facade 调用映射、取消、错误投影、离线结果和旧请求 generation 补齐单元/Widget 测试。

本包不得传入数据库、Cookie、文件、平台通道、callback 或 `host.*` handler；Facade 首次调用的自动启动完全由 Runtime 负责。

同级 Runtime 的 M1.2 `RuntimePingInvocation` 只是其内部 desktop communication proof，
尚不是本项目要接入的书架/阅读 capability。M2.2 仍须等待 Runtime 发布完整、版本化的公开
能力与阅读器适配；不得为了提前展示状态而复用其 test-only Desktop launcher、Node 路径、
HTTP endpoint 或 WS fixture。

## M2.3：纯 UI 计算与展示资源

M2.3 在 M2.2 验收后才开始，负责：

- 仅为 UI 自身的可序列化、非插件数据计算建立固定 worker 数和队列上限；不解析插件 HTML/正文、不校验 ZIP/摘要、不扫描文件或恢复下载。
- 为大列表、图片显示尺寸、进度事件降频、响应式布局、键鼠/触摸交互建立 UI 规则。
- 不创建 Runtime 文件布局、原子提交、缓存清理、下载检查点或数据库迁移；这些属于 Runtime。
- 为 UI 队列满、取消、旧 generation 和视图资源释放补齐单元/Widget 测试。

## M2.4：设置与诊断展示骨架

M2.4 在 M2.3 验收后才开始，负责：

- 设置与只读诊断页面骨架及明确入口。
- 消费 Runtime Facade 的脱敏 Runtime/插件/Store/缓存/恢复摘要和应用 UI 信息；不启动 Node、查询 Runtime Store、调用 raw URL 或绕过 Facade。
- 明亮、暗黑和系统主题接入既有语义主题；窄/宽布局保持同一信息层级。
- 键盘、鼠标、触摸焦点、命中区域和语义树测试；必要时在首发平台分别做人工运行验收。

## M2 总体完成条件

M2 只有在 UI 公开契约与 Runtime Facade 版本兼容路径已记录、受影响 Dart 单元/Widget
测试通过、格式与静态检查通过、真实 UI 运行验收按实际执行范围报告、且 UI 日志不包含
正文、用户标识、Cookie、令牌或 Runtime Store 内容时完成。Runtime 平台、存储和协议
验收由 Runtime 仓库单独报告，不能用 UI 测试代替。
