# ADR-0003：Node 24 与平台 Runtime 承载

- 状态：Accepted
- 日期：2026-08-13
- 决策者：MgRead 项目

## 背景

插件需要在 Android、Windows、macOS 使用一致的 ESM、网络、文件和运行时语义。桌面可以捆绑官方 Node，Android 需要嵌入式实现。候选包括 Javet、其他嵌入库、平台专属脚本引擎或远程服务。

Javet 当前支持 Android 和 Node 24，并允许 Java 与 Node Runtime 生命周期交互；但事件循环、Promise/Timer、关闭和异常行为仍需实际探针确认。[Javet](https://github.com/caoccao/Javet)；[Javet Node 交互](https://www.caoccao.com/Javet/tutorial/advanced/interact_with_node_js.html)

## 决策

- 插件 Runtime 统一基于 Node 24。
- Android 使用一个 Javet `NodeRuntime`，位于专用后台线程，不使用 Engine Pool。
- Windows/macOS 随应用捆绑固定版本的官方 Node 24 子进程，不依赖用户安装。
- 选择 Javet 版本后，以其实际携带的精确 Node 24 小版本为基准，桌面捆绑相同小版本。
- Android 最低 API 至少满足所选 Javet AAR 的要求；当前候选文档显示 API 24，正式版本以依赖探针为准。[Android 配置](https://github.com/caoccao/Javet/blob/main/android/javet-android/build.gradle.kts)
- Android 生产目标 `arm64-v8a`、模拟器/CI `x86_64`；Windows x64；macOS arm64/x64 分别出包。
- Node/Javet/Runtime Core/协议兼容矩阵整体升级，不能允许平台间小版本长期漂移。
- 正式实现前必须通过 M1 生命周期、ESM、HTTP/WS、文件、Range、异常和关闭探针。

## 后果

正面：

- 插件作者只面对一套标准 Node 能力和 MgRead Plugin API。
- 桌面发布可复现，不受用户 PATH、npm 和全局 Node 影响。
- Flutter Runtime Client 在三平台共用 WS/HTTP 协议，Android 不发展私有业务桥接。
- 分架构产物避免 macOS 一个包重复携带两套 Node。

代价与风险：

- Android 包体和 native ABI 管理成本显著增加。
- Javet 精确版本限制 Node 升级节奏，可能需要固定旧版或维护补丁。
- Node 的事件循环泵送和关闭需要 Javet 特定适配与 watchdog。
- macOS 包内 Node 必须纳入签名、Hardened Runtime 和公证。
- 三平台升级必须同步跑完整 Runtime 门禁。

## 被拒绝的方案

- **依赖用户电脑 Node**：版本、路径和安全不可复现。
- **Android 使用不同 JavaScript 引擎/语义**：插件兼容分裂，无法保证标准 Node Plugin API。
- **Android Engine Pool**：违反单 VM，并增加资源与状态一致性问题。
- **macOS universal 包内放两套 Node**：体积和签名复杂度增加；首版选择分包。
- **探针失败时静默换引擎或降级 Node**：破坏公开兼容承诺，必须先做替代 ADR。

## 变更条件

Javet 在可维护版本中无法满足必需探针、Node 24 进入不可接受的维护状态，或平台政策禁止当前承载方式时，才能提出替代 ADR。替代项需提供插件兼容、版本迁移、三平台包体/性能、生命周期和回滚证据。

## ADR-0008 职责澄清

本 ADR 的 Node 24/Javet/桌面 Node 选择保持 Accepted。文中“Flutter Runtime Client”只指
Runtime 为 Flutter 发布的集成门面，**不**表示 `mg_read` 主项目实现 Client、Supervisor、
Javet Adapter、桌面子进程或平台打包。自 ADR-0008 起，这些实现、探针与发布责任全部
属于 `mg_read_runtime`；主项目只调用其版本化 Facade。
