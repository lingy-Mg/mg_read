# 爱丽丝 Rust/Wasm 数据源模式效果报告

验证日期：2026-09-25。交付版本：`0.1.2`。插件 ID：`org.mgread.aisishuwu.wasm`。

## 结论

已实现可安装的 Rust → WebAssembly 二进制内核模式，并在 Windows 和 Android 的真实 Runtime 中执行。
两个平台复用同一个安装文件和 Wasm 字节。爱丽丝的发现、分类、搜索、详情、733 章完整目录、首/中/末正文及
详情封面代理均已通过定向平台验证。建议继续采用 Rust/Wasm 作为当前架构的二进制插件路线。

这是可运行的试验版。原 JS 来源继续保留；新来源尚未移植持久化缓存和原首页的轮播/原创专区细分编排。
Windows EXE 自动检查仍暴露宿主已有的超长正文限制，因此本报告不宣称所有书籍、所有显示表面全链路通过。
Java 本次完成接入成本和平台机制评估，没有实现 Java 数据源，表中的 Java 性能不作为实测结论。

## 实现与交付

```text
同一个 .mgplugin.js
  ├─ 内嵌 Rust 编译的 .wasm
  │    路由 / HTML 解析 / 字段投影 / 分页 / 目录 / 正文
  └─ 通用 ABI v1 适配器
       HTTP → ctx.http.fetch
       封面 → ctx.resource.proxy
       结果 → 现有 Runtime 校验 → Flutter Facade → 现有 UI
```

Wasm 在宿主已有 V8 内运行。发布端不附带源码、Cargo、crate、npm 依赖目录、DLL/SO 或 JVM；设备端不编译。
安装/导出/传输继续使用现有的单文件信封、SHA-256 与冷激活机制，未新增第二 VM 或原生插件加载器。

| 项目 | 最终产物 |
| --- | --- |
| 可安装文件 | `org.mgread.aisishuwu.wasm-0.1.2.mgplugin.js` |
| 安装文件大小 | 1,359,498 字节，约 1.30 MiB |
| 裸 Wasm 大小 | 1,015,973 字节，约 0.97 MiB |
| Wasm SHA-256 | `e16b257de4f969831a964fcf4d9dd2ca40555eea843fd05e1abc3e54baadc96e` |
| 安装文件 SHA-256 | `fbc3d61a4b88ef7fb24e9e7a7c966e6b8b30e7bd0edf2a09059d1c1bde5707e9` |
| Rust 工具链 | 1.97.1，`wasm32-unknown-unknown`，Cargo.lock 锁定依赖 |
| 宿主 SDK | `packages/mg_read_source_wasm`，ABI v1 |

复制出的交付文件与紧凑证据位于仓库 `artifacts/wasm-source/delivery/`。裸 `.wasm` 是二进制内核，
在 MgRead 中安装时选择 `.mgplugin.js`，无需额外安装裸 Wasm。

## 平台与链路证据

| 验证层 | 结果 | 范围 |
| --- | --- | --- |
| Rust 单测 | 3/3 通过 | URL/身份、正文清理、HTTP 200 拦截页 |
| 通用 ABI 适配器 | 3/3 通过 | 真正 Wasm 执行、ABI 拒绝、未知宿主操作拒绝 |
| 来源/安装离线测试 | 8/8 通过 | 公开结果校验、50 分类分组、并发状态、错误、HTTP 取消、64 MiB 内存上限、确定性打包与冷安装 |
| SDK 类型检查 | 通过 | 使用唯一公开 MgReadPluginContext 的消费端编译 |
| 线上快速检查 | 通过，约 47.3 秒 | 13 个发现表面、6 个子入口、6 个追加入口、250 个发现条目、8 个搜索条目、8 个热门词 |
| 线上阅读/资源抽样 | 通过 | 样本完整 65 章目录；首/中/末正文；发现各表面、搜索、详情封面各有成功抽样 |
| Windows 生产 Facade | 通过 | Node 26.10.0；独立数据根冷安装；发现/分类/搜索/详情/733 章目录/首中末正文/封面代理 |
| Android 默认后端 | 通过 | Android 15，`emulator-5556`，Javet / Node 26.9.0，x64；同一安装文件、相同完整阅读链路 |
| Android ARM64 路径 | 通过 | 同一 Android 15 模拟器的 ARM64 转译，Profile APK，私有 Node 24.21.0 后端；同一安装文件、733 章与首中末正文 |
| Windows Release EXE | partial | `0.9.251+369`；发现、搜索、详情、目录通过，自动选中的单章小说触发宿主正文大小限制 |
| Flutter 静态分析 | 通过 | 全仓 `flutter analyze --no-pub`，0 issues |
| 全仓源码规模检查 | 既有阻塞 | 未修改的 `comic_reader_chrome.dart` 为 1172 非空行，超过 1000；新增文件最大 416 非空行 |
| 全仓文档检查 | 既有阻塞 | 根 README 的 4 个锚点链接失效；本次新增文档没有剩余校验错误 |

Windows 与 Android 的定向平台样本均为 `novel:52801`，733 章无重复，首/中/末正文长度分别为
2490、2140、3555 个字符，两端一致，详情封面经生产资源代理返回 `image/png`。
Windows 首次无网络二进制调用为 8 ms；Android 默认后端为 28 ms，20 次热调用均值 12.25 ms。
ARM64 转译下的 Node 进程后端分别为 123 ms、7.53 ms，读取的目录和正文长度与默认后端完全一致。
这里包含各自 Facade/传输开销，不能把二者差值解释为 Wasm 在 Android 的纯计算性能。

另一次复用实验数据根的 Windows EXE 启动出现 `runtime_timeout`；已保留失败报告，使用新的隔离数据根后
正常进入来源调用，并再次稳定复现上述超长正文限制。没有把这次启动超时推断成 Rust/Wasm 缺陷。

Android 首次直连遇到域名解析/连接超时。成功验收通过现有电脑代理与本次 ADB reverse 映射完成，
来源实现不内置代理，也没有改设备全局网络设置。因此“网络无需代理”的结论不在本次证据范围内。
测试结束恢复正常应用入口，保留新来源安装；实际站点仍需可用网络。
本次临时 ADB reverse 映射已移除。

封面是按表面抽样，有一个搜索封面原站返回 404，后续候选成功；不代表所有封面都可达。
漫画页图、音频、视频/HLS 对这个小说来源不适用。未做 Android 物理真机或 UI 截图验收。

## 与原 JS 来源的开销对比

使用 Windows 固定 Node 26.10.0；每种方案启动 5 个独立进程，报告中位数。HTTP 使用同一份中性内存
fixture。新 ID 调用各 50 次，重复同一 ID 各 100 次。原 JS 为当前 `aisishuwu 0.2.12`。

| 指标 | 原 JS | Rust/Wasm 原型 |
| --- | ---: | ---: |
| 模块导入 | 10.05 ms | 4.97 ms |
| 首次详情调用 | 18.52 ms | 14.01 ms |
| 新 ID 详情调用均值 | 6.707 ms | 0.392 ms |
| 同一 ID 重复调用均值 | 0.0028 ms | 0.266 ms |
| 整个测试进程 RSS | 约 64.2 MiB | 约 64.2 MiB |
| 安装文件 | 520,362 B | 1,359,498 B |

新 ID 路径的实测均值较低，但原 JS 还执行缓存管理/磁盘写入，不能宣称 Rust 解析器本身快了约 17 倍。
重复同一 ID 时原 JS 命中内存缓存明显更快；当前 Wasm 原型仍请求/解析，每次约 0.27 ms 只是无网络 fixture
结果，真实网络下缓存缺失的代价会更大。尚无显著的进程内存节省证据。

当前 Wasm 安装文件约为原 JS 的 2.61 倍；其中包含 HTML parser、URL/IDNA、JSON 和 Rust 支撑代码，
base64 内嵌还有约 33% 编码增量。原 JS 文件含图标，两个安装文件的附属资源并非完全一致。

## Rust 与 Java 的优势、劣势

| 方案 | Windows / Android 实现路径 | 优势 | 代价与适用判断 |
| --- | --- | --- | --- |
| Rust → Wasm，本次选择 | 相同 Wasm 在已有 V8 执行 | 单一二进制、无平台动态库矩阵；编译期检查；不直接开放 OS 能力；复用现有安装和 HTTP | 包体较大；需要 JSON/内存桥接；仍依赖 Node/V8；异步通过 continuation 实现；当前缓存/UI 编排未达原版完整度 |
| Rust 原生 | Windows DLL，Android 各 ABI 的 SO，增加宿主 FFI | 可直接利用原生 API；适合以后整体原生化 Runtime | 需要平台/ABI 构建和加载生命周期；原生崩溃隔离、符号、升级兼容均需新增工程；本次未实现 |
| Java | Windows JVM/JAR；Android 经 D8 转为 DEX、接入 ART | JVM 生态成熟，Android 原生集成自然，解析库选择多 | 标准 JAR 与 Android DEX 不同；Windows 要提供/依赖 JVM；与现有 Node Context 另做桥接及异常/取消/生命周期管理；本次未实测性能 |
| 现有 JS | 现有 Node/Javet | 开发更新快、包体更小、当前缓存和页面编排完整 | 代码以 JS 分发；计算密集逻辑缺少 Rust 的编译期约束；继续适合一般来源 |

结合当前 MgRead 已在两个平台拥有 V8 的事实，优先 Rust/Wasm 是接入成本判断，而不是“所有场景 Rust
都比 Java 快”的语言排名。Rust 的该 target 默认没有宿主系统能力，需要由调用方提供网络等服务，正好
对应这里的公开 Context 桥接。[Rust target 文档](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html)
与 [Node WebAssembly 文档](https://nodejs.org/learn/getting-started/nodejs-with-webassembly)。

Java 字节码到 Android DEX 的转换机制见 [Android D8 官方文档](https://developer.android.com/tools/d8)。
HTML 解析采用 Rust scraper 的 CSS selector 接口，版本在项目中精确锁定，见
[scraper 官方 crate 文档](https://docs.rs/scraper/0.27.0/scraper/)。

## 明确的限制与后续取舍

1. **继承宿主正文限额。** Runtime 单次小说正文目前上限 48 KiB。EXE 自动样本 `novel:3211` 的原 JS
   返回 79,143 B，新实现返回 67,619 B，二者均被现有验证器拒绝。去除空白后的 SHA-256 完全相同，差异是
   空白归一化，没有靠截断正文取巧。要覆盖此类长章，需要另行设计宿主的大正文传输/分段契约。
2. **缓存和首页布局有差距。** 本次验证二进制模式和完整数据链路；大规模替换前应移植原来源缓存策略与
   首页分组，同时增加相同页面/相同网络条件下的 A/B 测量。
3. **不等于安全沙箱或加密。** 二进制可反编译；外层 JS 仍拥有现有 Node 插件权限；同步 Wasm 无限循环
   不能被同一 V8 内的超时抢占。64 MiB 是 Rust 参考模块的线性内存上限，不是整个 Runtime 的硬预算。
4. **保留来源级差异。** 目前覆盖 HTTP 与封面代理；WebView 会话、文件 IO、媒体线路等能力没有扩展进
   ABI v1。这些来源需要后续按公开 Context 逐项补充，而不是让 Wasm 获取私有宿主对象。

可复现命令和源码职责记录在 `plugins/sources/aisishuwu-wasm/AGENTS.md`；ABI 文档位于
`packages/mg_read_source_wasm/README.md`。构建机在来源目录执行 `npm.cmd ci --ignore-scripts`、
`npm.cmd run verify`，即可生成相同格式的安装文件。设备上通过 MgRead 数据源管理导入该文件。
