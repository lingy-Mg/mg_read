# 爱丽丝独立原生数据源效果报告

> 本文是 ABI v1 / 0.1.0 的历史验收记录，不代表当前 v2。当前设计及验证入口见
> [v2 实现契约](../../../packages/mg_read_native_runtime/IMPLEMENTATION_CONTRACT.md)。


> 当前交付说明（2026-09-26）：现行打包脚本只生成一份通用 `.mgplugin`，内含 Windows x64 与 Android arm64 两个目标；扫码或局域网传输时只发送接收平台对应的目标。使用 NanaZip 7.0（2609.2）以标准 ZIP Deflate 高压参数打包。下文是 2026-09-25 的历史验收记录，其中 Android x86_64 与旧包体积、哈希不代表当前交付。

日期：2026-09-25。App 版本：0.10.0+370；原生来源：`org.mgread.aisishuwu.native` 0.1.0。

## 结论与实现

采用 Rust 原生宿主与 Rust 动态库来源。Windows 运行独立 EXE 并加载 DLL，Android 在私有
`:mgread_native` Service 进程中运行 APK 内置 Rust 宿主、加载导入包中的 SO。来源的 HTTP、文件、
缓存、封面、安装索引和执行均由 Rust 拥有。新模式不经过 Node、Javet、V8 或 JS 适配器。

同一份来源源码编译为 Windows x64、Android x86_64 和 Android arm64 三种机器码，再合成一个 `.mgplugin`
安装包。这是跨平台源码和安装包，不是单一可执行机器码。

Flutter 仍使用唯一强类型 `PluginRuntime`。编译参数 `MGREAD_NATIVE_RUNTIME=true` 选择原生后端，Windows
构建移除旧 runtime 资产，Android 原生变体排除 Javet/Node 依赖和实现。旧来源与旧引擎保留为另一构建模式，
本版不同时运行两套引擎。

## HTTP、文件与 ABI

原生来源通过稳定 C 函数表调用宿主服务，运行时直接用 reqwest/Tokio 发出网络请求、用 Rust 文件 API
读写插件私有 `data/cache`。没有 Node Context 或由 Dart 转发网络请求。保留宿主 API 是为了统一代理、
取消、缓存目录和配额；它不意味着依赖 Node。

当前 HTTP SDK 覆盖爱丽丝所需的 HTTPS GET、请求头、重定向、显式/系统代理、20 秒请求超时及真实网络取消。
正文 HTTP 上限 4 MiB，来源结果上限 8 MiB，小说单章上限 1 MiB，目录上限 5000 条；不截断长正文。
文件每份上限 8 MiB，每个插件的每个存储区域上限 64 MiB，写入使用临时文件后替换。缓存保存资源描述，
重启后重新登记封面地址。

C ABI 仅传递函数表、借用指针及 UTF-8 JSON 缓冲区，分配者负责释放。同步 C 调用运行在 worker 线程，
异步 HTTP 留在宿主 Tokio 执行器。原规划的任务轮询 ABI 简化为 `invoke/release`；Windows 命名管道及
Android 大结果 Binder 方案改为由 Rust 直接持有的鉴权 loopback HTTP。Binder/stdout 仅返回小型启动信息。

更新先写完整候选目录后原子发布，通过 worker 冷重启切换。进入待激活版本之前持久化上一确认版本，
避免激活崩溃造成无限重试。动态库在 worker 存活期间不卸载。取消先等待真实任务退出；超出宽限仍未退出，
Supervisor 结束 worker。原生进程意外退出后，下次调用启动新 worker，不自动重放失败请求。

## 已完成的实测

| 层级 | 结果与证据 |
| --- | --- |
| Rust 核心 / Windows DLL | 实际导入包、HTTPS、私有文件、路径拒绝、取消、错误 ABI/校验和拒绝、重启、更新、导出、卸载已通过 |
| Node 缺席核心运行 | worker 的 PATH 仅含 Windows System32；已加载模块只有 Rust 宿主、爱丽丝 DLL 与系统库，无 Node/Javet/V8 |
| Windows Flutter Facade | 真实宿主与安装包通过发现、分类、搜索、建议词、详情、完整目录、首中末正文及封面；worker 强杀后恢复 |
| Windows 生产 App | Debug、Release 构建通过；Release EXE 的公开 `--source-check` 全链路通过，来源发现/搜索/详情/目录/正文/封面均成功 |
| Windows 交付 ZIP | 解压最终 ZIP 后再运行生产 EXE，自检 14.4 秒通过；PATH 无 Node、包内无旧 Runtime；附宿主所需 MSVC CRT |
| Android x86_64 | MuMu Android 15、Debug APK：真实导入、启停、发现/分类/搜索、完整目录、长正文、封面、Service 重启及 App 搜索→详情→阅读全部通过 |
| Android ARM64 | 同一模拟器的 ARM64 转译、Profile APK：同一完整流程通过；读者页面显示内容与来源结果匹配，状态页显示 android · aarch64 |
| 跨架构恢复 | 保留已安装版本和数据，缺失当前架构动态库时从原包恢复并校验 SHA-256；损坏恢复目标被拒绝 |
| 长正文 | 长章样本 UTF-8 为 67,619 字节，超过旧实验 48 KiB 边界，完整通过 Rust 与 Dart 解码；报告不分发正文 |
| 持久化 | 文件跨 worker 重启读取；关闭上游访问后详情缓存仍命中；强杀 worker 后缓存命中没有发出上游请求 |

线上样本 `novel:52801` 本次实测目录 733 章且无重复 ID，与详情计数相符；该数字只描述当前样本，不是测试
写死的预期。首、中、末正文分别为 7,282、6,250、10,277 UTF-8 字节。Rust 直调与 Flutter Facade 的正文
SHA-256 相同。封面实收 49,309 字节，格式为 PNG。

Windows 最终 Facade 样本：宿主冷启动 67 ms、导入及重启 115 ms、强杀后恢复 202 ms、重启后详情缓存
读取 6 ms。这些是单次整合测试结果，不能当作稳定性能分布，也不据此声称全面快于 JS。

原始证据在 `artifacts/native-runtime/windows-core.json` 与
`plugins/sources/aisishuwu-native/artifacts/native-runtime/windows-facade-report.json`；报告只记录数量、
哈希、时间和状态，不记录正文、控制 token 或代理凭据。

Android 验收设备为用户已开启的 MuMu，屏幕 720×1280、逻辑宽度 360、系统页大小 4096 字节。
已逐张检查 x86_64 与 ARM64 的运行状态截图：Rust 引擎健康、爱丽丝 0.1.0 启用，布局无溢出。
实际窄屏首次启动页曾出现底部溢出，已改为内容决定高度，并补充 320/360/390 宽度测试。

两种 Android ABI 都装载 `libmgread_native_runtime.so` 和 `libaisishuwu_native.so`，未装载 Node/Javet。
切换 APK 架构时发现旧安装目录只有此前 ABI 的 SO，已修复为从完整包恢复当前 ABI 并校验哈希；设备上保留
原来的 x86_64 文件，同时新增 arm64 文件，安装索引和数据未清空。Profile UI 测试另外修复了测试键盘
未注册导致输入被 Flutter 忽略的问题，未修改生产输入框行为。

状态页单次 worker RSS 为 x86_64 141.0 MB、ARM64 转译 182.4 MB。Android 私有进程还包含 ART、zygote
共享映射及转译成本，不能直接与下方 Windows RSS 相比，也没有 Android 旧引擎的同条件内存基线。
长章样本的封面上游返回 404；另一个有效样本的 PNG 封面完整通过，不将上游缺图记为 Runtime 解析成功。

## 同条件 Windows 性能对比

通过公开 Flutter Facade 对旧 JS 0.2.12 与原生 0.1.0 各测三组。双方使用相同书籍 `52801`、同一首章及
相同代理；每个方法先清理持久缓存、销毁清理 worker，再创建全新 worker，避免旧来源内存缓存干扰。
下表为三次中位数，启动时间包括创建 Runtime、配置代理和首次 ping；请求计时不含启动、缓存清理和状态采样。

| 指标 | Rust 原生 | Node 26.10.0 + JS |
| --- | ---: | ---: |
| 详情组进程启动 | 39 ms | 178 ms |
| 详情请求 | 970 ms | 1020 ms |
| 目录请求 | 1094 ms | 1257 ms |
| 正文请求 | 1227 ms | 952 ms |
| 启动后 worker RSS（详情组） | 7.67 MiB | 62.28 MiB |
| 详情请求后 worker RSS | 9.80 MiB | 72.35 MiB |
| 目录请求后 worker RSS | 10.31 MiB | 78.48 MiB |
| 正文请求后 worker RSS | 9.65 MiB | 73.68 MiB |

这组数据支持“原生 worker 启动更快、常驻内存更低”。本轮详情和目录较快，正文较慢，网络耗时没有一致优势。
RSS 是具体时点的 worker 内存，不是峰值或整个 Flutter App 内存；此测试也没有模拟操作系统文件缓存冷态。
原始记录位于 `plugins/sources/aisishuwu-native/artifacts/native-runtime/windows-facade-benchmark.json`。

目录 ID 和详情章数一致。正文原始哈希不同：Rust 合并非空行为段落，旧 JS 保留另一种换行布局。
另取同一份实时 HTML 快照交给两种解析器，去除 Unicode 空白后的正文 SHA-256 完全相同，没有非空白正文
丢失或增加。因此保留原始哈希差异，并单独记录去空白后的等价性，不把两种排版说成字节完全一致。

## 优势与代价

| 项目 | 本方案的实际影响 |
| --- | --- |
| 独立性 | 来源和宿主使用原生二进制；用户设备不需要 Node、npm、Rust 工具链或另装 JVM |
| 体积 | 三目标来源包 5,118,979 字节；Windows 宿主 3,767,296 字节（3.59 MiB）。整个 Flutter App 还包含媒体等其他库，不能把宿主体积当 App 体积 |
| 复用 | 来源解析、路由和发现组合用同一 Rust 源码；页面、书架和阅读器沿用 Flutter 公开内容语义 |
| 性能 | 消除了 Node/JS 调度，但真实站点延迟、缓存策略和 IPC 仍会影响表现；比较时必须统一输入与缓存条件 |
| 开发成本 | 需要 Windows、Android 双 ABI 编译、NDK 和 C ABI 生命周期管理；修改来源后需重新打包 |
| 隔离 | worker 崩溃与 Flutter 分离，但原生代码拥有所属 OS 用户/Android App 的权限，SDK 路径和配额不是安全沙箱 |
| 分发 | 每目标二进制不同，可信插件包须维护 ABI、版本和平台哈希；自带 SHA-256 只能验证完整性，不证明作者身份 |

当前旧爱丽丝 JS 0.2.12 单文件为 520,362 字节，新原生包因携带三个架构二进制而更大；本地固定 Node
26.10.0 的 `node.exe` 为 104,714,056 字节。原生宿主更小，但这些是具体文件的比较，不能代替整 App
安装体积或内存比较。

| 候选 | Windows / Android 交付 | 与本需求的关系 |
| --- | --- | --- |
| Rust 原生（已实现） | EXE + DLL / 私有 Service + SO；来源按目标架构编译 | 不需要另装语言运行时，适合可信二进制来源；承担 ABI 和多目标构建成本 |
| Java（方案评估） | Windows JVM + JAR / Android ART + DEX | 可共享业务源码，但普通 JAR 不能直接等同于 Android 可加载 DEX；Windows 仍要分发或依赖 JVM |

本次选择 Rust，把执行和 I/O 所有权直接放进原生引擎。Java 没有做同条件实测，不给出速度排名。

## 构建与使用

在仓库根目录使用 Rust 1.97.1、NDK 28.2.13676358 及仓库 Flutter 环境：

```powershell
./tools/build_native_runtime.ps1 -Platform all
./plugins/sources/aisishuwu-native/tools/build.ps1
flutter build windows --release --dart-define=MGREAD_NATIVE_RUNTIME=true --no-pub
flutter build apk --release --target-platform android-arm64,android-x64 --dart-define=MGREAD_NATIVE_RUNTIME=true --no-pub
```

安装原生模式 App 后，从数据源管理的本地导入入口选择 `aisishuwu-native-0.1.0.mgplugin`，启用“爱丽丝书屋
Native”，即可在发现/搜索中选择该来源并打开详情和小说阅读器。代理从现有网络代理设置配置；本次线上
验收通过工作站代理，不能据此保证当前网络环境直连可用。

原生构建只识别原生来源包，旧 `.mgplugin.js` 来源需要旧构建模式。新来源使用独立 ID，不自动把旧来源的
书架记录改成原生来源；需要在新来源中重新选择对应作品。本次不迁移或删除旧来源数据。

## 范围与限制

本版完成小说来源能力；WebView/Browser Profile、Cookie 会话、POST、漫画、音视频/HLS 和 Range 尚未实现。
原生入口对未支持能力返回 `unsupported`，不会回退 Node。局域网来源传输的公开导入/导出边界单独验证，
不据此宣称整套局域网配对产品流程已回归。

Android 模拟器的实际 ABI、页大小及转译结果须单列；ARM64 转译不是 ARM64 真机。原生宿主和来源 ELF
按 16 KiB 页对齐构建，不等同于完成整 App 的 16 KiB 设备验收。应用商店动态代码分发与正式签名不是本次
本地交付验收范围。

## 最终产物与检查

交付目录为 `artifacts/native-delivery/0.10.0/`。Windows ZIP 已包含来源包及 app-local MSVC CRT；Android
APK 同时包含 arm64-v8a 和 x86_64 宿主，需要另外导入同目录的来源包。APK 使用正常 `lib/main.dart`
Release 入口，已通过指定 x86_64 的覆盖安装和启动验证，主进程与原生 Service 同时存活。
最终审计逐项核对两个 ABI 的 Rust 宿主、Flutter 引擎和 Dart AOT 文件，避免沿用旧 Release 规则裁掉 x86_64。
完整页面流程的证据来自前述 Debug/Profile 集成测试，不能把它写成 Release 全链路自动化。
APK 沿用仓库现有本地调试签名配置，不是应用商店正式签名包。

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| MgRead-0.10.0-native-windows-x64.zip | 70,012,692 | `cbe88facf466b99a80ee78316f765797b610f429668f6664ef2b2328c7d8cb47` |
| MgRead-0.10.0-native-android.apk | 74,510,877 | `82fc03f1704ef59e5e5d818c25fd97febec3f04887d58d2f212010ea8def537b` |
| aisishuwu-native-0.1.0.mgplugin | 5,118,979 | `b2c6ce34360e09948f52f7331857056dc9d81b6e8b96e29849aae86ce35b503b` |

`evidence/` 收录计数、哈希、状态、配对性能记录及经过检查的运行状态截图；不收录正文和失败日志。
`delivery.json` 记录代码提交与文件清单，`SHA256SUMS.txt` 可校验交付内容。

Rust 宿主 5 项测试、来源 8 项测试、原生 Supervisor 8 项测试通过；Facade、旧桌面 Runtime、状态页面和
窄屏布局的直接测试通过。最终重跑的默认模式页面/App 测试 25 项、原生模式页面测试 16 项全部通过，
Windows 真实 Facade 与三组对照基准通过；旧 Android Javet 的 4 个测试套件、8 项测试通过。
全仓 `flutter analyze` 无问题；本次 17 份 Dart 文件格式检查无改动。

收尾 `-Mode Final` 被既有源码规模问题阻止：`comic_reader_chrome.dart` 有 1172 非空行，超过 1000 上限；
新代码均未超过硬上限。另行完成了上述静态分析与直接测试。文档检查仍报告 README 中既有 4 个锚点问题，
本次新文档没有新增链接错误。没有把这两项现存问题写成全仓检查通过，也没有修改无关文件来隐藏结果。

技术依据：[Rust 动态库链接](https://doc.rust-lang.org/reference/linkage.html)、
[Android 进程与线程](https://developer.android.com/guide/components/processes-and-threads)、
[Android 执行权限变化](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)、
[Android 16 KiB 支持](https://developer.android.com/guide/practices/page-sizes)、
[D8 字节码转换](https://developer.android.com/tools/d8)、
[MSVC 本地部署](https://learn.microsoft.com/en-us/cpp/windows/choosing-a-deployment-method?view=msvc-170)。
