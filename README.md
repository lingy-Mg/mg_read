# MgRead

`MgRead` 是以插件为在线数据来源的本地优先小说/漫画阅读应用的 Flutter 主项目。它拥有路由、主题、页面、用户交互、阅读器视图宿主和应用权威持久化；`mg_read_runtime` 只负责插件执行与平台 Runtime。独立的 `novel_reader_ui` Flutter 插件只负责阅读器体验。

首版承诺 Android、Windows 和 macOS，Android 优先。iOS、Linux 和 Web 暂不在支持范围。

## 当前状态

仓库当前已有可运行的 Flutter 应用壳、Riverpod 组合根、类型化路由、语义主题、顶层导航、
书架入口、“我的”页，以及仅提供安全本地交互的“关于我们”与“意见反馈”页面；小说阅读器
继续只通过公开接入点集成。主应用已具备后台 SQLite metadata persistence，以及启动前完成
初始化、纯内存读取、分组合流写入和 CAS 恢复的全局 settings 门面。它现在通过同级
`mg_read_runtime` 的版本化 Flutter Facade 显示 Runtime/Node 健康与已安装插件状态；主项目没有
Node、端口、WS 或 data-root 代码。“我的 → 调试日志”提供应用/Runtime 分页关键日志、仅内存
实时详情和显式详情 TXT 模式；默认不会读取或保存 HTTP/JSON/HTML/小说正文。以下能力尚未实现：

- Runtime 安装/更新/仓库 UI，以及由 Runtime 驱动的书架和下载页面。
- 更新检查、协议/隐私/许可/联系内容、截图选择和反馈提交等真实 capability；当前详情页不访问网络、文件或持久化。
- 由 `mg_read_runtime` 独立实现的官方仓库、完整 Store、缓存、下载、大资源 HTTP 与跨平台承载。
- Windows/macOS 的 UI 发布适配；Runtime 的 Node/Javet、签名和平台包由 Runtime 仓库验收。

同级 `mg_read_runtime` 已实现 Windows desktop bootstrap 与标准 Node 插件切片：Runtime 自行
以 Job Object 纳管固定 Node 进程树，完成 ready/HTTP/WS 门禁，按 package/lock 安装依赖并在
冷启动加载插件，通过 `RuntimePingInvocation`、`InstalledPluginsInvocation` 和
`SourceDiscoverInvocation`、`SourceSearchInvocation`、`SourceDetailInvocation`、
`SourceChaptersInvocation`、`SourceContentInvocation` 投影强类型结果。主项目的搜索和发现页
已经消费这套 Facade；Node/Flutter 自动化已验证列表与五个内容能力。这仍不表示完整 Runtime
Store、大资源数据面、阅读器数据、Android/Javet、macOS 包或最终应用包已验收。

本仓库只消费这些已发布 Facade，并提供“我的 → 书源管理”的 Runtime 状态页以及真实搜索/发现
投影；不得在这里引入 Node/Javet、WS/HTTP Client、Runtime 数据库/文件、Cookie、callback 或
其他运行时代码。主应用自己的 persistence/settings 不能向 Runtime 注入路径或连接。后续能力
仍必须先在 Runtime 仓库以版本化 Facade 发布，再由本项目增加 UI 消费。

## 架构入口

完整文档从 [docs/architecture/README.md](docs/architecture/README.md) 开始：

- [产品范围与实施路线](docs/architecture/01-product-roadmap.md)
- [系统分层与组件边界](docs/architecture/02-system-architecture.md)
- [Runtime 生命周期与平台探针](docs/architecture/03-runtime-lifecycle.md)
- [标准 Node 插件、依赖安装与官方仓库](docs/architecture/04-plugin-sdk-packaging-registry.md)
- [Runtime 内部 WS/HTTP 协议](docs/architecture/05-transport-protocol.md)
- [数据、缓存与恢复下载](docs/architecture/06-domain-data-cache-downloads.md)
- [并发与性能规范](docs/architecture/07-concurrency-performance.md)
- [可靠性、可观测性与测试](docs/architecture/08-reliability-observability-testing.md)
- [平台发布与未来 WebView/媒体边界](docs/architecture/09-platform-release-future-capabilities.md)
- [主应用持久化设计](docs/architecture/10-app-persistence-design.md)
- [主应用持久化独立验收规范](docs/architecture/11-app-persistence-acceptance.md)
- [全局设置内存门面与异步持久化](docs/architecture/12-global-settings.md)
- [插件内容 API v1 与空值语义](docs/architecture/15-plugin-content-contract.md)
- [已接受 ADR](docs/architecture/adr/README.md)

核心决策是：每个应用进程只有一个可信 Node 24 VM；Android 由 Runtime 自有单个 Javet `NodeRuntime` 承载，Windows/macOS 使用 Runtime 自有的固定官方 Node 子进程；WS/HTTP 是 Runtime 内部实现；主应用 SQLite 是应用权威元数据来源，Runtime 不得获得其路径或连接；主项目只调用强类型 Runtime Facade，且不向 Runtime 注入数据库、文件、Cookie、平台或 `host.*` 服务；插件更新在下次应用进程启动时冷激活。

## 首版闭环

- 唯一官方插件仓库与本地 `.mgplugin` 安装。
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

当前本地已有主项目、阅读器插件、Runtime 和标准插件模板；registry 名称仍是计划：

| 仓库 | 职责 |
| --- | --- |
| `mg_read` | Flutter UI、路由、主题、用户交互、阅读器视图宿主和 Runtime 结果的 UI 投影；不实现或注入 Runtime |
| `mg_read_reader_ui` | 独立 Flutter 小说/漫画阅读器插件 |
| `mg_read_runtime` | 完整独立插件运行时：Flutter-facing Facade、平台承载、Node Core、内部 WS/HTTP、Runtime Store、Plugin API、Schema 与 fixture |
| `mg_read_plugin_template` | 已创建的标准 Node 空白项目、多文件 TypeScript、本地 package、构建/校验/打包/契约测试 |
| `mg_read_plugin_registry` | 唯一官方插件索引、包和发布自动化 |

## 当前与目标目录

当前 Flutter 代码按以下依赖方向维护：`app -> features -> core/shared`。

```text
lib/
  app/                    # 应用入口、主题、路由和集中可见文案
  core/                   # 应用 persistence、settings、错误映射及无 Runtime 职责的基础能力
  features/
    library/              # 当前已有：书架入口
    reader/               # 当前已有：阅读器用例、适配与宿主页
    plugins/              # 当前已有：Runtime 状态/插件列表 Facade 投影；安装管理后续接入
    diagnostics/          # 当前已有：应用/Runtime 关键日志与限时详情查看器
    discovery/            # 当前已有：Runtime Facade 搜索/发现状态、适配器和 UI 投影
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

存在 Dart/Flutter 测试资产时还要执行 `flutter test`。本仓库后续实现补齐 UI 单元/Widget/Facade 消费测试；Node、共享协议、Runtime Store、集成测试和三个首发平台的 Runtime 冒烟由 `mg_read_runtime` 维护并分别报告。Runtime Store 还必须通过不依赖主应用、Node、网络或真实用户数据的独立验收套件。Golden 在视觉规范稳定后按需启用。

静态检查、自动化测试、应用运行、桌面平台验收、Android 真机原生验收与发布验收必须分别报告，不能互相替代。
