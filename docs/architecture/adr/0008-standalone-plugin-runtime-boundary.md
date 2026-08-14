# ADR-0008：独立插件运行时与零主项目注入

- 状态：Superseded by ADR-0011
- 日期：2026-08-13
- 决策者：MgRead 项目
- 取代：[ADR-0005](0005-host-database-authority.md)

## 背景

插件执行、平台承载、进程或 Javet 生命周期、协议协商、WS/HTTP、资源流、缓存、
下载、Cookie、安装状态和恢复本身是一套跨平台运行时。把其中一部分放进 Flutter 主
应用会迫使 `mg_read` 维护 Runtime Supervisor、平台桥接、反向 RPC、数据库提交和
协议细节；这些实现会渗透到 feature、Repository 和页面，既污染 UI 工程，也会让
Android、Windows、macOS 的行为难以保持一致。

此前 ADR-0005 选择 Flutter 数据库权威、Node 通过 `host.storage.*` 回调提交状态。
该模型要求主项目注入持久化、Cookie、文件等能力，与“运行时可独立运行、主项目只
调用插件能力”的目标冲突。

## 决策

- `mg_read_runtime` 是完整、可独立运行的插件运行时产品，而不是仅供主项目拼装的
  Node Core。它拥有 Runtime Core、平台承载、生命周期、内部通信、Plugin API、安装
  更新、资源服务、缓存、下载、Cookie、诊断、恢复和其需要的持久化。
- Android Javet Adapter、Windows/macOS Node 启动与打包集成、Runtime Supervisor、
  WS Client/Server、HTTP 数据面和所有协议 envelope 都由 Runtime 仓库中的内部组件
  实现和测试。它们不得在 `mg_read` 中重新实现。
- Runtime 对 Flutter 主项目只发布一个版本化、强类型的高层门面。主项目以
  `PluginInvocation(pluginId, capability, params)` 调用插件或 Runtime 管理能力，并
  获得强类型结果、资源对象或脱敏状态；不得接触端口、ready、bootId、Javet、子进程、
  WebSocket、HTTP URL、原始 envelope 或重连逻辑。
- 门面在首次调用时自行完成初始化、版本核对、健康探测与内部连接管理。主项目不传入
  初始化回调、数据库连接/路径、Cookie、文件服务、平台通道或 `host.*` handler。
- Runtime 拥有全部插件和内容来源相关的持久状态：插件安装与版本、书架/来源绑定、
  目录快照、阅读进度、书签、下载、内容/缓存文件、插件 KV、Cookie、设置和脱敏
  Runtime 诊断。主项目只消费 Runtime 返回的投影并保存短期 UI 状态。
- `host.*` 不再是 v1 的跨仓库公开协议。未来需要文件选择、WebView、通知、媒体或
  其他平台能力时，必须在 `mg_read_runtime` 内实现对应跨平台能力并扩展其公开门面；
  不得用主项目回调或依赖注入作为绕过边界的通道。
- `mg_read` 只负责 UI、路由、用户交互、主题、阅读器视图宿主和将 Runtime 结果映射
  为 view state。阅读器所需的数据源和状态存储适配也由 Runtime 发布的 Flutter
  集成包提供，主项目不得自行实现插件通信或持久化适配。

本 ADR 保留 ADR-0001 的单 VM、ADR-0002 的可信插件、ADR-0003 的 Node/Javet 平台
承载、ADR-0004 的 WS 控制面/HTTP 数据面及 ADR-0006 的冷激活结论。它改变的是这些
能力的仓库所有权和主项目可见性：WS/HTTP 仍可作为 Runtime 内部实现，绝不是主项目
公开集成面。

## 后果

正面：

- 主项目保持 UI 与产品用例边界，不承载平台 Runtime、协议或插件基础设施。
- 三个平台只有一套 Runtime 生命周期、存储恢复、通信和诊断实现，能独立探针和发布。
- 插件能力可通过单一强类型门面演进，主项目不会因协议细节或新增 Runtime 能力而扩散
  回调与状态机。
- Runtime 可脱离 `mg_read` 进行启动、插件、存储、网络和平台验收；主项目测试可用
  门面替身专注 UI 行为。

代价与限制：

- `mg_read_runtime` 将包含未来的 Flutter-facing 集成包及 Android/桌面内部适配，不再
  仅是 TypeScript Core；这些内容仍须在 Runtime 仓库按平台单独验证。
- Runtime 需要自己解析受控应用数据根目录、管理 Runtime Store/文件布局和平台服务，不能向
  主项目索取路径或能力。
- 主项目不能绕过门面访问 Runtime 数据库或文件。任何新产品数据需求必须先成为
  Runtime 的版本化 capability/schema，再由 UI 消费。
- Runtime 的独立性不改变首版可信插件、单 VM 和平台原生限制；同步插件死循环仍可能
  使整个 Runtime 不可用。

## 被拒绝的方案

- **主项目注入 `HostPort` / `host.*` handler**：看似抽象，实际把存储、Cookie、文件和
  平台能力的复杂度重新带回主项目，并使 Runtime 不能独立运行。
- **主项目持有 Runtime Supervisor 或 WS/HTTP Client**：会让启动、重连、错误和平台
  差异扩散到 Flutter feature，违背单一运行时边界。
- **Runtime 只拥有 Node，主项目分别实现 Android 和桌面承载**：会产生两套生命周期
  与测试责任，未来极易发生协议和版本漂移。
- **用动态 Map/string 直接暴露内部协议**：会让 UI 对 envelope、端口和 wire schema
  耦合；公开门面必须以版本化强类型调用对象和结果类型表达。

## 迁移与执行规则

1. `mg_read` 删除或不再新增 `core/runtime` Supervisor、WS/HTTP Client、Javet/Node
   启动、`host.*` handler、插件/内容数据库和文件恢复实现。
2. `mg_read_runtime` 先定义独立 Runtime 门面、内部存储边界及平台集成包，再实现相应
   Runtime 里程碑；M1.1 骨架不因此提前实现业务代码。
3. 共享 Schema/fixture 的发布与兼容检查由 Runtime 仓库负责；主项目只消费门面公开
   的版本化类型。
4. 新能力若需要平台原生实现，先在 Runtime 仓库设计、探针和发布，随后以 capability
   形式提供给 UI；不得临时反向注入主项目服务。

## 变更条件

只有当 Runtime 无法在目标平台独立实现某项能力，且有可验证的替代边界、数据迁移、
版本兼容、平台测试和 UI 降级方案时，才能提出新的替代 ADR。不能以开发方便为由恢复
主项目注入或将 Runtime 通信代码搬回 `mg_read`。
