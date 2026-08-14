# MgRead

`MgRead` 是以插件为全部在线数据来源的本地优先小说/漫画阅读应用的 Flutter UI 主项目。它拥有路由、主题、页面、用户交互和阅读器视图宿主；完整插件能力、书架/进度等插件数据、持久化、缓存、下载、平台承载与通信全部由独立的 `mg_read_runtime` 提供。独立的 `novel_reader_ui` Flutter 插件只负责阅读器体验。

首版承诺 Android、Windows 和 macOS，Android 优先。iOS、Linux 和 Web 暂不在支持范围。

## 当前状态

仓库当前已有可运行的 Flutter 应用壳、语义主题、书架入口和小说阅读器公开接入点。以下能力尚未实现：

- Runtime Facade 的正式接入及由其驱动的插件中心、书架、发现、下载和诊断页面。
- Riverpod 组合根、类型化路由和 UI-facing 状态投影。
- 由 `mg_read_runtime` 独立实现的插件 SDK、ZIP 安装、官方仓库、更新、回滚、存储、缓存、下载与跨平台承载。
- Windows/macOS 的 UI 发布适配；Runtime 的 Node/Javet、签名和平台包由 Runtime 仓库验收。

同级 `mg_read_runtime` 已独立完成 M1.2 的 Windows desktop bootstrap 通信测试：它只验证
Runtime 自行启动固定 Node、内部 ready/HTTP/WS 门禁和诊断性 `RuntimePingInvocation`。这不
是本主项目的依赖或 UI 功能接入，不表示插件、Runtime Store、阅读器数据、Android/Javet、
macOS 包或任何业务 capability 已可用。

本仓库当前阶段仍只交付 UI 壳、架构、协议、开发规范、ADR 和路线图；不得为使用该 M1.2
验证路径在这里引入 Node/Javet、WS/HTTP Client、数据库、文件、Cookie、callback 或其他
运行时代码。Runtime 真实能力只在其仓库成熟后以版本化 Facade 发布并由本项目消费。

## 架构入口

完整文档从 [docs/architecture/README.md](docs/architecture/README.md) 开始：

- [产品范围与实施路线](docs/architecture/01-product-roadmap.md)
- [系统分层与组件边界](docs/architecture/02-system-architecture.md)
- [Runtime 生命周期与平台探针](docs/architecture/03-runtime-lifecycle.md)
- [插件 SDK、ZIP 与官方仓库](docs/architecture/04-plugin-sdk-packaging-registry.md)
- [Runtime 内部 WS/HTTP 协议](docs/architecture/05-transport-protocol.md)
- [数据、缓存与恢复下载](docs/architecture/06-domain-data-cache-downloads.md)
- [并发与性能规范](docs/architecture/07-concurrency-performance.md)
- [可靠性、可观测性与测试](docs/architecture/08-reliability-observability-testing.md)
- [平台发布与未来 WebView/媒体边界](docs/architecture/09-platform-release-future-capabilities.md)
- [已接受 ADR](docs/architecture/adr/README.md)

核心决策是：每个应用进程只有一个可信 Node 24 VM；Android 由 Runtime 自有单个 Javet `NodeRuntime` 承载，Windows/macOS 使用 Runtime 自有的固定官方 Node 子进程；WS/HTTP 是 Runtime 内部实现；Runtime Store 是插件与内容数据权威；主项目只调用强类型 Runtime Facade，且不注入任何数据库、文件、Cookie、平台或 `host.*` 服务；插件更新在下次应用进程启动时冷激活。

## 首版闭环

- 唯一官方插件仓库与本地 ZIP 安装。
- 插件安装、更新、启停、诊断和失败回滚。
- 发现、搜索、详情、目录和加入书架。
- 小说/漫画阅读、语义进度、书签、缓存和可恢复下载。
- 插件不可用时保留书架快照、进度、书签与已下载内容。

音频、视频、WebView 登录、账号和云同步只定义扩展边界，不属于首版验收。插件首版完全可信，不实现安全沙箱、签名信任链、权限强制或本地通信鉴权。

## 与阅读器插件的关系

开发时通过同级目录的本地 path 依赖接入阅读器：

```text
Desktop/
  mg_read/                # 本项目：Flutter 主应用
  mg_read_reader_ui/      # 已存在：novel_reader_ui Flutter plugin
```

主应用只能导入：

```dart
import 'package:novel_reader_ui/novel_reader_ui.dart';
```

禁止深层导入阅读器插件的 `lib/src/`。`mg_read_runtime` 将发布其公开的 `TextReaderDataSource`、`TextReaderStateStore`、`ComicReaderDataSource`、`ComicReaderStateStore` 和 Runtime capability 适配；主应用只将其交给阅读器视图，不实现插件通信、进度持久化或书源网络。

当前的 `lib/features/reader/application/reader_launch_request.dart` 与 `lib/features/reader/presentation/reader_host_page.dart` 是已建立的小说阅读器视图宿主边界。真实数据、缓存、状态适配和插件能力必须位于 `mg_read_runtime`，不能塞入页面、feature data/application 或 core。

## 目标仓库边界

除前两个当前本地项目外，其余名称是计划，尚不表示仓库已经创建：

| 仓库 | 职责 |
| --- | --- |
| `mg_read` | Flutter UI、路由、主题、用户交互、阅读器视图宿主和 Runtime 结果的 UI 投影；不实现或注入 Runtime |
| `mg_read_reader_ui` | 独立 Flutter 小说/漫画阅读器插件 |
| `mg_read_runtime` | 完整独立插件运行时：Flutter-facing Facade、平台承载、Node Core、内部 WS/HTTP、Runtime Store、SDK、Schema 与 fixture |
| `mg_read_plugin_template` | 空白项目、假数据插件、构建/校验/打包/契约测试 |
| `mg_read_plugin_registry` | 唯一官方插件索引、包和发布自动化 |

## 当前与目标目录

当前 Flutter 代码按以下依赖方向维护：`app -> features -> core/shared`。

```text
lib/
  app/                    # 应用入口、主题、路由和集中可见文案
  core/                   # UI 错误映射、诊断投影和其他无 Runtime 职责的基础能力
  features/
    library/              # 当前已有：书架入口
    reader/               # 当前已有：阅读器用例、适配与宿主页
    plugins/              # 计划：插件管理
    discovery/            # 当前已有：发现页 UI 预览；搜索与 Runtime 接入计划
    content_detail/       # 计划：详情与目录
    downloads/            # 计划：缓存与下载
    settings/             # 计划：设置与诊断入口
  shared/                 # 真正跨 feature 的 UI 与工具
docs/
  architecture/           # 架构、协议、规范、路线图与 ADR
```

计划目录只在对应里程碑创建。本仓库根目录是唯一 Flutter 主应用，不创建嵌套 `example/` 或第二个 App。

## 开发流程

开始任何修改前，完整阅读 [AGENTS.md](AGENTS.md) 和相关架构专题，检查 `git status --short` 并保留无关脏改动。大型实现按“公开契约/领域 → 纯逻辑与适配器 → UI → 原生 → 验证”推进。

本地运行当前应用壳：

```powershell
cd C:\Users\q3499\Desktop\mg_read
flutter pub get
flutter run
```

每次修改至少执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```

存在 Dart/Flutter 测试资产时还要执行 `flutter test`。本仓库后续实现补齐 UI 单元/Widget/Facade 消费测试；Node、共享协议、Runtime Store、集成测试和三个首发平台的 Runtime 冒烟由 `mg_read_runtime` 维护并分别报告。Golden 在视觉规范稳定后按需启用。

静态检查、自动化测试、应用运行、桌面平台验收、Android 真机原生验收与发布验收必须分别报告，不能互相替代。
