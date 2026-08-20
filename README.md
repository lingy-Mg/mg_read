# MgRead

`MgRead` 是以插件为在线数据来源的本地优先小说/漫画阅读应用。根目录是 Flutter 主应用，
拥有路由、主题、页面、阅读器宿主和应用权威持久化；`packages/mg_read_runtime` 负责插件执行、
平台 Runtime 与内部通信；`packages/mg_read_reader_ui` 只负责阅读体验。

首版承诺 Android、Windows 和 macOS，Android 优先。iOS、Linux 和 Web 暂不在支持范围。

## 当前状态

仓库当前已有可运行的 Flutter 应用壳、Riverpod 组合根、类型化路由、语义主题、顶层导航、
书架入口、“我的”页，以及仅提供安全本地交互的“关于我们”与“意见反馈”页面；小说阅读器
继续只通过公开接入点集成。主应用已具备后台 SQLite metadata persistence，以及启动前完成
初始化、纯内存读取、分组合流写入和 CAS 恢复的全局 settings 门面。它现在通过
`packages/mg_read_runtime` 的版本化 Flutter Facade 显示 Runtime/Node 健康与已安装插件状态；主项目没有
Node、端口、WS 或 data-root 代码。“我的 → 调试日志”提供应用/Runtime 分页关键日志、仅内存
实时详情和显式详情 TXT 模式；默认不会读取或保存 HTTP/JSON/HTML/小说正文。以下能力尚未实现：

- Runtime 安装/更新/仓库 UI，以及由 Runtime 驱动的书架和下载页面。
- 更新检查、协议/隐私/许可/联系内容、截图选择和反馈提交等真实 capability；当前详情页不访问网络、文件或持久化。
- Runtime 官方仓库/大资源 HTTP/跨平台承载，以及尚未由 Accepted ADR 固定的下载 checkpoint
  与跨边界文件提交。
- Windows/macOS 的 UI 发布适配；Runtime 的 Node/Javet、签名和平台包由 Runtime 仓库验收。

`packages/mg_read_runtime` 已实现 Windows desktop bootstrap 与标准 Node 插件切片：Runtime 自行
以 Job Object 纳管固定 Node 进程树，完成 ready/HTTP/WS 门禁，按 package/lock 安装依赖并在
冷启动加载插件，通过 `RuntimePingInvocation`、`InstalledPluginsInvocation` 和
`SourceDiscoverInvocation`、`SourceSearchInvocation`、`SourceDetailInvocation`、
`SourceChaptersInvocation`、`SourceContentInvocation` 投影强类型结果。主项目的搜索和发现页
已经消费这套 Facade；Node/Flutter 自动化已验证列表与五个内容能力。这仍不表示完整 Runtime
Store 型业务持久化、大资源数据面、正式入库阅读链路、Android/Javet、macOS 包或最终应用包
已验收。主应用业务数据权威仍是 `AppPersistence`/`ContentLibrary`。

本仓库只消费这些已发布 Facade，并提供“我的 → 书源管理”的 Runtime 状态页以及真实搜索/发现
投影；不得在这里引入 Node/Javet、WS/HTTP Client、Runtime 数据库/文件、Cookie、callback 或
其他运行时代码。主应用自己的 persistence/settings 不能向 Runtime 注入路径或连接。后续能力
仍必须先在 Runtime 仓库以版本化 Facade 发布，再由本项目增加 UI 消费。

## 架构入口

文档总入口是 [docs/README.md](docs/README.md)。AI/开发任务先读根 `AGENTS.md`，再从
[渐进式开发路由](docs/development/README.md)选择当前任务；不要预加载下面全部专题。

架构总入口是 [docs/architecture/README.md](docs/architecture/README.md)：

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
- [全局日志与诊断数据](docs/architecture/14-global-diagnostics-logging.md)
- [插件内容 API v1 与空值语义](docs/architecture/15-plugin-content-contract.md)
- [Content Library](docs/architecture/20-content-library.md)
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

开发时通过 monorepo 内的本地 path 依赖接入阅读器和 Runtime：

```text
mg_read/                  # monorepo 根与 Flutter 主应用
  packages/
    mg_read_reader_ui/    # novel_reader_ui Flutter plugin
    mg_read_runtime/      # Runtime 与 Flutter Facade
  templates/
    mg_read_plugin_template/ # 官方标准 Node 插件模板
```

主应用只能导入：

```dart
import 'package:novel_reader_ui/novel_reader_ui.dart';
```

禁止深层导入阅读器插件的 `lib/src/`。主应用 reader data adapter 组合 Runtime Facade 的在线
结果与主应用 Content Library/状态窄端口，实现阅读器公开的 DataSource/StateStore；页面既不
实现插件通信，也不直接操作 SQLite。

当前的 `lib/features/reader/application/reader_launch_request.dart` 与
`lib/features/reader/presentation/reader_host_page.dart` 是小说阅读器视图宿主边界。真实网络/
插件执行属于 Runtime；正式业务持久化属于主应用 Content Library；页面不得承接任一基础设施。

## Monorepo 子项目边界

当前 monorepo 已包含主项目、阅读器插件、Runtime 和标准插件模板；registry 子项目仍是计划：

| 子项目 | 职责 |
| --- | --- |
| 根目录 `mg_read` | Flutter UI、路由、主题、用户交互、阅读器视图宿主和 Runtime 结果的 UI 投影；不实现或注入 Runtime |
| `packages/mg_read_reader_ui` | 独立 Flutter 小说/漫画阅读器插件 |
| `packages/mg_read_runtime` | 独立插件运行时：Flutter-facing Facade、平台承载、Node Core、内部 WS/HTTP、插件安装/私有运行数据、Plugin API、Schema 与 fixture；不拥有主应用业务库 |
| `templates/mg_read_plugin_template` | 标准 Node 空白项目、多文件 TypeScript、本地 package、构建/校验/打包/契约测试 |
| `plugins/sources/aisishuwu` | 爱丽丝书屋的实际标准 Node 书源；独立源码、在线 smoke 测试与 `.mgplugin` 发布物 |
| 计划中的 `mg_read_plugin_registry` | 唯一官方插件索引、包和发布自动化 |

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

开始任何修改前，完整阅读 [AGENTS.md](AGENTS.md)，再从
[开发文档路由](docs/development/README.md)选择最窄专题集；检查 `git status --short` 并保留无关
脏改动。大型实现按“公开契约/领域 → 纯逻辑与适配器 → UI → 原生 → 验证”推进。

本地运行 Windows 发现链路（先构建书源包并由 Runtime 自己阶段化；主应用不传递书源路径）：

```powershell
cd C:\Users\q3499\Desktop\mg_read
cd plugins\sources\aisishuwu
npm ci --ignore-scripts
npm run verify
cd ..\..\..
cd packages\mg_read_runtime
npm run stage:flutter-windows
cd ..\..
flutter pub get
flutter run
```

每次修改至少执行：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```

代码改动还要执行 `flutter test`。主应用维护 persistence、Content Library、reader adapter、UI
单元/Widget/Facade 消费测试；Node、共享协议、插件执行、Runtime 操作数据、集成测试和三个首发
平台的 Runtime 冒烟由 `packages/mg_read_runtime` 维护并分别报告。Golden 在视觉规范稳定后按需
启用。

子项目不随根 `flutter analyze` 递归分析；涉及它们时进入各自目录执行其所有者命令：阅读器插件执行根包与 `example/` 的 `flutter analyze`，Runtime 使用其固定 Node 24.16.0 后执行 `npm run verify:desktop`，插件模板执行 `npm run verify`。这保持单一 Git 工作流，同时不混合各子项目独立的 lint 与平台验收边界。

静态检查、自动化测试、应用运行、桌面平台验收、Android 真机原生验收与发布验收必须分别报告，不能互相替代。
