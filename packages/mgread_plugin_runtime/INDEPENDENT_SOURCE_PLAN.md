# 独立数据源运行时重新规划

日期：2026-09-25。状态：原生实现已接入，平台验收结果见爱丽丝原生来源的效果报告。
所有者：Runtime Facade 与平台宿主；本文记录路线决策和验收门槛，实际 ABI 由原生 runtime 与 Source API 共同拥有。
需求依据：用户明确要求独立于 Node，支持 Windows 和 Android，以爱丽丝验证二进制数据源。

## 1. 目标与路线决策

主线采用 **Rust 原生宿主 + Rust 原生数据源插件 + 稳定 C ABI**。一份来源源码，分别编译 Windows DLL、
Android SO；可以合成一个安装包，但不是两个平台执行同一份机器码。

独立性的完成定义：新来源的安装、启停、调用、HTTP、私有文件、缓存、封面代理、更新和卸载都不经过
Node、Javet、V8、JS 适配器或 Node 的目录索引。测试必须使用实际不包含这些运行库和资源的构建产物。
最终用户设备不需要 Rust 工具链、npm、Java 开发工具或额外安装 JVM。

| 候选 | Windows / Android | HTTP 与文件 | 主要代价 | 决策 |
| --- | --- | --- | --- | --- |
| Rust 原生插件 | DLL / 按 ABI 编译的 SO | 原生 Rust 宿主提供统一服务；插件有原生库生态可用 | 多目标构建、C ABI、原生崩溃恢复、Android 外部 SO 装载验证 | 首选 |
| Rust + 独立 Wasm 引擎 | 两端内置引擎，插件可以使用同一 Wasm | 原生宿主绑定或 WASI；需要实现与验证 I/O 边界 | 引擎部署、异步/取消/资源绑定、Android 支持和包体测试 | 备选；需要单一可执行插件字节或更强隔离时再投入 |
| Java | Windows JVM/JAR，Android ART/DEX | 两端标准库及共同 SDK 的兼容子集 | Windows JVM 交付、JAR/DEX 两套产物、API 兼容与跨语言接入 | 暂不实现 |
| 当前 Node 内嵌 Wasm | 两端现有 Node/V8 | 现有 Context | 无法满足独立性要求 | 仅保留为历史实验 |

Rust 的 `cdylib` 用于向其他语言交付系统动态库，支持 DLL/SO 等形式，见
[Rust linkage](https://doc.rust-lang.org/reference/linkage.html)。Android 的 D8 把 Java 字节码转换为 DEX，
因此“Java 源码可共用”不等于“普通 JAR 直接在两端运行”，见 [D8](https://developer.android.com/tools/d8)。
独立 Wasm 并非不可行；例如 Wasmtime 官方说明 Android 受支持但测试少于主要平台，不能把桌面成功推算为
Android 可交付，见 [平台支持](https://docs.wasmtime.dev/stability-platform-support.html)。

## 2. 运行结构与 I/O

```text
MgRead Flutter 页面 / 书架 / 阅读器
                    |
        唯一的强类型 PluginRuntime Facade
                    |
          Native Supervisor 与私有 IPC
          /                         \
Windows 宿主 EXE                Android 私有 Service 进程
Job Object 生命周期             APK 内置 JNI / Rust 宿主 SO
          \                         /
             Rust 原生 Runtime Core
          安装、目录索引、HTTP、存储、资源代理
                    |
                 C ABI v1
                    |
         爱丽丝 DLL / 对应 Android ABI 的 SO
```

- 来源路由、HTML 解析、发现组合、分页和结果投影属于插件；宿主不含爱丽丝站点知识。
- HTTP 在原生 Runtime 内执行。插件在阻塞工作线程调用宿主函数，宿主使用 Tokio/reqwest 异步执行真实 I/O，
  统一处理代理、超时、取消和重定向。普通请求不绕道 Dart、Kotlin 或 JS；v1 只实现爱丽丝所需的 HTTPS GET，
  Cookie 会话、POST 和浏览器会话未纳入本版 SDK。
- 文件在原生 Runtime 管理的插件 `data/cache` 目录内读写，SDK 提供相对路径、原子写入和配额接口；
  支持进程重启后读取。主应用数据库仍由 Flutter 拥有。
- 这些 SDK 能力是管理约定，不是恶意原生代码的安全沙箱。原生插件可以绕过 SDK；v1 只承载可信插件。
- 封面由 Rust Runtime 的资源服务代取，Flutter 仅消费已有资源语义。控制 IPC 不搬运整张图片或整段视频。
  漫画、音视频/HLS、Range 和 Browser Profile 等未完成的能力明确返回 `unsupported`，不得借 Node 补齐。
- WebView 本身仍由 Windows WebView2 / Android WebView 平台宿主持有。爱丽丝首轮只验证普通 HTTP，
  WebView 的通用原生绑定属于后续独立能力，不能宣称已覆盖所有旧来源。

Android 采用 `android:process` 将 Service 与 Flutter 分开；Service 方法仍须在后台线程执行，不能阻塞
Service 主线程，见 [Android 进程与线程](https://developer.android.com/guide/components/processes-and-threads)。
Android 10 对应用可写目录中的 `execve` 有限制，所以不把“复制一个 Rust 可执行文件再启动”作为 Android
方案，见 [执行权限说明](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)。
APK 内置宿主与外部插件 SO 的证据分开记录；不能只凭 APK 内库存在就推断动态插件可用。

## 3. ABI、生命周期与故障边界

以下为已实现的 v1；相对初稿，简化了任务 ABI，并统一两端控制传输：

- 单一导出入口 `mg_source_get_api_v1` 返回带版本及结构大小的 C 函数表；宿主在执行来源能力前验证版本。
- 来源表只有 `invoke/release`，每次调用借用 `HostApi`；来源无常驻实例。运行时在工作线程上执行同步 C ABI，
  不跨动态库传递 Rust `String`、`Vec`、trait、Future 或运行时对象。避免在 v1 同时维护两套任务调度系统。
- 宿主函数表同样带版本/结构大小；HTTP、文件和取消查询通过 `call` 执行，结果用 `release` 释放。调度和
  真实网络取消属于宿主；同步 C 边界不会把 HTTP 放到 Flutter 或 Android Service 主线程。
- 数据使用 UTF-8 JSON 和 `(pointer, length)` 缓冲区；分配者释放自己的内存。宿主复制完成后才通知释放，
  回调和任务生命周期必须在关闭前结束，错误及 panic 不得跨 C 边界展开。
- 内容语义复用 `discover/search/searchSuggestions/getDetail/getChapters/getContent`。JSON 约束及
  conformance fixture 由 `mg_read_source_api` 拥有，Rust SDK 与 Dart Facade 共同验证，避免两套公开内容协议。
  现有包含 `nodeVersion`、JS `Response` 的 Context 继续服务 JS；原生 SDK 不伪造这些字段。
- 两端都由 Rust 拥有随机端口的 loopback HTTP 控制服务，用每次启动随机 token 鉴权并拒绝带 Origin 的请求。
  Windows stdout / Android Binder 只返回启动端口与 token。目录和长正文直接经有界 HTTP，不通过 Binder，
  不在 Dart 再建服务器。封面使用不可猜测的资源 URL，Rust 直接流式代取。
- v1 每个应用运行一个原生 worker，插件按需加载；HTTP 可并发。原生崩溃会影响该 worker 的全部在途调用，
  但不应结束 Flutter 主进程。先完成在途调用的确定性失败，再允许重新启动；不自动重放插件请求。
- 普通取消应停止排队和真实网络 I/O。CPU 死循环等无法合作取消的任务由 Supervisor 超时后终止 worker；
  不能用 Dart 提前返回冒充任务终止，也不能把独立进程误称为权限隔离。
- 不在运行中卸载 DLL/SO。更新写入不可变候选目录，排空或取消调用并重启 worker 后切换；失败保留上一
  已确认版本。卸载先停用并重启 worker，再回收已释放的文件，避免 Windows 文件占用与悬空函数指针。

## 4. 安装与交付

使用 `format=mgread-native, engine=native, abi=1` 的 `.mgplugin` ZIP，包含 manifest 与目标二进制。
它由新原生安装器处理；不兼容旧 Node 安装器。包体不含源码、Cargo/npm 依赖目录或设备端编译步骤。

```text
manifest.json                 id / version / engine / ABI / targets / capabilities / hashes
windows-x86_64/source.dll
android-arm64-v8a/libsource.so
android-x86_64/libsource.so    当前模拟器验证目标
```

- 允许完整多平台包或只含一个目标的精简包；安装器只装载当前目标，缺少目标时返回清晰错误。
- 安装先校验归档路径、文件上限、目标 ABI、版本和哈希，再原子发布目录。哈希表示完整性，不等于作者可信。
- Android 从系统选择器的 `content://` 流导入到 Runtime 私有版本目录；插件不读取选择器 URI。
- Android 外部 SO、依赖库可见性、最低 API 与 16 KiB 页兼容必须实测。不能把 ARM64 转译当作 ARM64 真机。
  页大小依据 [Android 16 KiB 支持说明](https://developer.android.com/guide/practices/page-sizes)。
- 第一阶段使用本地导入验证；远程分发与应用商店渠道另行核实，不由本方案假定动态原生代码适用于所有渠道。

## 5. 仓库改动所有权与旧方案处理

| 位置 | 计划职责 |
| --- | --- |
| `packages/mg_read_native_runtime/` | Rust Core、C ABI/SDK、Windows 宿主、Android 宿主库、原生安装器与资源服务 |
| `packages/mgread_plugin_runtime/` | 现有唯一 Facade 增加 Native Supervisor；选择器、进程管理、内部 IPC、平台 WebView 接口 |
| `packages/mg_read_source_api/` | 共享内容语义、版本和契约 fixture；保留现有 JS 类型，避免来源自行复制公共定义 |
| `plugins/sources/aisishuwu-native/` | 爱丽丝原生来源、构建、fixture、双平台效果报告 |
| 根构建及测试工具 | 同一 Flutter App 的 native-only 构建、包内容审计、定向 EXE 与 Android 验收 |

`PluginRuntime()` 工厂通过编译时 `MGREAD_NATIVE_RUNTIME=true` 选择 Native Supervisor，接管初始化、
安装列表、启停、传输和资源调用，不调用旧 Node manager 获取基础信息。

先在同一个 App 增加 native-only 构建配置：Windows 排除 Node 资产，Android 用明确的构建变体排除
Javet/libnode、JS 资产及直接引用它们的 Kotlin 源码。仅设置运行时布尔开关或没有 Node 子进程不算独立证据。
v1 用显式引擎配置选择原生或旧 Node 后端，不同时启动两套引擎。旧来源文件和数据保留；native-only 模式
明确只支持原生来源。混合运行若后续实施，应在 Facade 按引擎路由并保持 Node 延迟启动，另作验证，不成为
原生来源运行的前置条件。

复用现有爱丽丝的纯 Rust 解析、URL/ID 逻辑和测试样本；将 continuation 调度替换成原生异步调用，补齐
持久化缓存。旧 `aisishuwu-wasm` 与 `mg_read_source_wasm` 作为实验保留，不继续扩展它们的 Node 适配器。
旧实验测试结果仍有效，但不计入此次独立运行时验收。

现行核心规范的“唯一 Node VM、单 JS artifact、禁止原生 loader”等规则描述旧引擎。用户此次明确要求新
独立模式，实施时同步修改这些规则的适用范围及 package 规则；不把新原生插件伪装成 Node native addon。

## 6. 实施顺序与阶段门槛

| 阶段 | 具体工作 | 通过条件 |
| --- | --- | --- |
| 0：双平台最小独立验证 | 在当前 App 集成最小原生宿主；从外部包加载测试 DLL/SO；执行 HTTPS、文件写入/重启读取、取消；试更新及错误 ABI | Windows 和当前 Android 模拟器真实通过；无 Node/Javet/V8 装载；Android 外部 SO 装载与冷更新无阻塞 |
| 1：契约和管理 | 固定 ABI、SDK、安装格式、错误、取消、目录索引、不可变版本与进程恢复 | 独立 Rust 测试、跨 ABI fixture、并发/释放/越界输入测试；Node 缺失时冷安装和管理通过 |
| 2：爱丽丝纵向闭环 | 移植来源；生产 Facade 调用发现、搜索、详情、完整目录和正文；封面由 Rust 代取；缓存重启命中 | 当前真实样本完整阅读链路；无 JS 转发；站点失败与协议失败可区分 |
| 3：真实 App 与故障 | Windows EXE 与 Android 正常页面操作；取消、断网、代理、强杀 worker、升级失败恢复、卸载 | Flutter 不随 worker 结束；不重复执行请求；两端冷重启后来源仍可用；原生安装/读取路径全部经过正式入口 |
| 4：交付与报告 | native-only 构建和安装包、哈希、体积/冷启动/内存/延迟报告、验证范围及复现步骤 | 独立性证据齐全；明确区分模拟器、ARM64 转译、真机；不以旧 Wasm 报告替代 |

阶段 0 必须先于完整来源迁移。若外部原生库加载遇到不可接受的平台或交付限制，记录具体失败，再转评估
独立 Wasm 宿主；不回退到 Node 执行后宣布原生路线成功。没有 ARM64 真机或 16 KiB 环境时，这两项保持
未验证，当前已开启的模拟器结果只覆盖它的实际 ABI 和页大小。

## 7. 验收矩阵与效果报告

1. **独立性**：对交付 APK/Windows 目录检查 Node/Javet/V8 二进制和 Runtime JS 资产缺席；观察真实进程及
   已加载模块；在 Node 不可用环境执行冷安装、列来源、发现、阅读、资源、重启和卸载。
2. **平台**：Windows x64、Android x86_64 模拟器分别有生产 Facade 和 App 证据；Android arm64 另列
   原生设备或转译证据。实际环境、App/插件版本、ABI、安装包哈希、网络代理条件必须记录。
3. **来源**：根发现/子列表/分页、搜索/建议词、详情、完整无重复目录、首中末正文、各展示位置封面。
   当前目录规模以线上结果为准，不把旧报告的 733 章写死为新成功条件。
4. **长正文**：加入上轮触发 48 KiB 限制的真实样本与中性长文本 fixture。核对原生宿主、公共契约、Facade、
   主应用保存和阅读各层；需要扩大限制时公开调整契约并回归，不截断或只换短样本规避。
5. **存储与故障**：插件间私有数据区分、持久化/缓存、取消后连接释放、并发状态、worker 崩溃和超时恢复、
   更新时占用与失败回滚。只报告可实际强制的边界，不宣称 SDK 路径规则能够约束恶意 native 代码。
6. **性能**：与原 JS 在相同输入、缓存状态、代理及设备上比较；分别测空 App、宿主启动、首次来源加载、
   冷/热请求、总进程内存、宿主体积及单 ABI/完整插件包体。线上网络与离线解析分列，不预设更快更省内存。

最终报告包含可安装产物和 SHA-256、操作路径、Node 缺席证据、Windows/Android 功能结果、HTTP 与文件持久化、
故障恢复、性能条件和未验证项。新增 Rust 依赖在 Cargo.toml 精确固定并提交 Cargo.lock；结果以
[爱丽丝原生效果报告](../../plugins/sources/aisishuwu-native/EFFECT_REPORT.md) 为准。
