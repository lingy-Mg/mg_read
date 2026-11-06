# mg_read_node_runtime 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Node.js Runtime package 的所有权、任务路由和固定工具链。

## 按任务读取

- Node Core、安装、artifact、协议或插件调用：从目标实现、公开类型、fixture 和直接测试开始。
- Flutter Facade：转到同级 `../mgread_plugin_runtime/`，读取其最近 `AGENTS.md`、公开入口和相邻测试。
- Node/Javet/ABI 升级：只读 [版本矩阵](docs/runtime-version-matrix.md)的当前选择、平台和待验证部分。
- WebView provider/宿主：读目标平台实现、公开 provider 类型和直接 contract；只有数据源公开能力也变化时
  才加载 `mgread-source-development` 技能的对应 WebView 参考。
- 不同时预加载 Node、Facade、Android、Windows、模板和真实数据源材料。

## Package 所有权

- Windows/macOS 的 JS Core 支持 Node 26.10.0 与 Bun 1.4.4；Bun 通过精确版本和 SHA-512 固定的
  官方 `@oven` 分发包暂存，不依赖全局 Bun，不在生产安装 npm 包。构建与开发热更新仍用固定 Node/npm。
  Bun 使用打包的 Undici Fetch，不能使用忽略 dispatcher 的 Bun 原生 fetch 代替来源代理传输；
  Bun 没有 `net.client.socket` 观测时如实输出 `not_observed`。来源 API 与数据根在两后端保持一致。
  桌面 staging 同时交付两套 helper；运行 `test:bun` 和 `verify:staged-bun`，macOS helper 签名包含 Bun。
  Windows 发布 Core 由 `tools/bundle-windows-runtime.mjs` 合并为 `dist/cli.js`，另保留三个 inspector 静态文件；
  调试映射只存于构建目录。Windows CMake 删除其他平台资产；最终包用 `MGREAD_WINDOWS_BUNDLE_ROOT` 和
  `MGREAD_BUN_BUNDLE_ROOT` 执行两个 staged 验证，防止开发依赖、编译碎片和其他平台文件回流。
  根 `tools/check_source_runtime_compatibility.mjs` 在固定 Node/Bun 上逐源运行同一套离线测试，CI 可用
  `--install-dependencies` 从各源 lock 恢复开发依赖；`--concurrency=2` 仅并发独立来源，每源命令仍串行。
  调度边界由 `tools/source_compatibility_scheduler.test.mjs` 验证；离线通过不等于真实站点或 App 全链路通过。

- Android staging 只发布原路径、原字节的可执行模块和调试页，不发布 `.d.ts`、`.map`、`windows-release`。
  `cli.js`（私有 Node 进程）与 `desktop-runtime.js`（Javet）必须同时保留；内容指纹驱动宿主替换私有程序镜像，
  不清理用户插件数据。`test/android-runtime-staging.test.mjs` 验证完整文件集、字节和指纹；根
  `tools/verify_android_release.py` 校验最终 APK 的平台资产、双入口、ABI、ELF 和原生库压缩。
  本地与 Actions 发布入口见 [发布打包](docs/release-packaging.md)。

- 发现 `filters` 的分组/选项预算与选中 ID 关联由 `plugin-content-discovery.ts` 校验；`plugin-content-tree.test.mjs`
  保留 45 选项与非法选择/重复/超限回归。原有首个根 `tabs` 的约束不变。

- 数据源执行输入仅为构建期已内联第三方包的单个 JS；archive 只是容器，不是 npm 项目分发机制。
  Runtime 不解析来源 lock、不恢复或缓存 npm 依赖，也不复制/链接开发项目依赖树。
  安装、导入、导出、同步和删除共用此约束，不新增依赖引用扫描或模块加载拦截。
- 本 package 独立拥有 Node.js Runtime Core、desktop launcher、内部控制/数据面、Plugin API、安装、
  schema/fixture 和瞬时诊断；同级 `mgread_plugin_runtime` 拥有 Flutter Facade、Supervisor 与平台宿主。
- `sourceUrl` 是可缺省的展示元数据，局域网传输、导入、索引修复与执行统一兼容缺省值，不补造网址、
  不改写不可变版本；显式提供的无效 URL 仍失败。隔离或损坏来源调用返回加载失败，不报未安装。
- 主应用只调用版本化 `PluginRuntime.invoke`；不得获得 executable、PID、端口、ready、bootId、内部 URL、
  wire envelope、Runtime 数据根或平台对象。
- 每个应用进程只有一个 Node Runtime/VM。installed pending 只在冷启动激活并提交或回滚；已确认的 current
  与 development 项目先建立元数据快照，首次能力调用或传输时单飞加载。development 构建变化仍须先激活
  候选 generation，成功后才替换并回收旧 generation。
- Runtime 私有数据不得承载书架、目录、正文、进度、书签或主应用设置权威。
- `PluginManager` 组合安装与 generation 生命周期；`PluginContentDispatcher` 独占来源能力调用、租约和结果关联校验，
  `PluginManagerStorage` 独占路径解析、占用测量与缓存清理。新增能力不得把这些职责重新堆回 Manager。
- Android embedded 的私有 `__mgreadLoadPluginModule` 可返回 namespace 或其 Promise；Core 必须等待模块
  求值后再激活来源，宿主不得在加载回调中嵌套推进 Node 事件循环。回归为 `test/android-javet-async.test.mjs`。
- 批量收件箱共用 32 MiB/文件、512 MiB/批限制，不按 32 个文件截断；pending 冷激活并发上限为桌面 8、
  embedded 4，各插件独立提交或回滚。HTTP 关闭先取消所有在途响应（包含换代理前的旧响应），避免重启等待响应体。
  `plugin-batch-startup.test.mjs` 与 `plugin-http-shutdown.test.mjs` 覆盖这些边界；稳定目录命中仍不执行插件代码。
- 传输类型、错误与纯校验由 `plugin-transfer-contract.ts` 拥有；manager 与批次 IO 单向依赖该契约。
  `test/android-runtime-import-graph.test.mjs` 检查编译后 Core 启动图，禁止静态循环引用进入 Android Javet。
- `plugin-import-batch.ts` 统一 Windows/Android 批次 manifest、CRC、包内 ID/版本预检，校验整批后才能开始安装。
  `.batch-<id>.part` 由平台宿主拥有，Core 只消费一次目录 rename 发布的 `batch-<id>`；完整批次保留至安装结束，
  中断后幂等重放，坏批次消费后报错。覆盖同版本时，保留 artifact 必须与最终版本树同步替换。
- 自动更新批次声明 `updatesOnly=true`，只接受 installed artifact；收件箱消费前复核 current/pending 与
  uninstall-pending，跳过缺失、已移除、同版本和已有更高版本的来源。Core 不消费宿主尚未发布的 `update-*` 目录。
- Runtime-only 任务不修改主应用 UI、Reader、模板或真实数据源，除非用户把对应公开边界纳入同一任务。
- `hls-ad-analysis.ts`、`hls-ad-projection.ts` 和 `hls-ad-filter.ts` 消费来源或宿主登记的 `hlsAdFilter`：学习主分片族、差异直方图筛选、闭合异类区间及三次有界 TS 前缀时钟复核。`host-video-ad-filter.ts` 将资源 resolve 的宿主 `filterVideoAds` 偏好投影到单次播放描述：开启时保留有效来源策略或提供通用策略，关闭时移除来源策略，缺省不改原描述；不持久化 App 设置。无把握保留原清单；规则只继承给子清单，二进制分片仍流式转发。直接回归为 `hls-ad-filter.test.mjs`、`hls-ad-loopback.test.mjs` 与 `host-video-ad-filter.test.mjs`。
- 系统代理对字面量 loopback 目标的绕过由 HTTP dispatcher 逐跳保证；Undici 7 的 NO_PROXY 不支持 CIDR。
  显式书源代理保持覆盖语义。连接排查见 `docs/plugin-http-routing.md`；独立探针不代表 App 现场状态。
- HTTP 失败上下文经现有异常链和 Debug 事件输出；请求开始时冻结配置，连接观测按异步调用隔离，
  不另建日志通道，不在新增上下文中携带代理凭据、URL 路径/查询或请求头。

## 固定工具链与验证

Windows 将 `tools/node-v26.10.0-win-x64` 放到 `PATH` 最前，使用 Node 26.10.0/npm 11.19.1；
macOS arm64 将 `tools/node-v26.10.0-darwin-arm64/bin` 放到 `PATH` 最前，使用 Node 26.10.0/npm 11.19.1，
不回退全局 Node/npm。按受影响边界运行 package scripts 和直接测试；不要机械执行无关平台矩阵。
固定 npm 的依赖 `dist` 是工具链源码分发的一部分，Windows/macOS 都必须跟踪，不能被应用 `dist/` 忽略规则排除。
macOS 代理回归需要 `127.173.137.161` 的 lo0 alias，CI 在测试前配置、结束后清理；本地跑该套测试也需先配置。

- Node Core：固定 npm 运行 `typecheck`、直接 Node 测试、`check:no-native-addons`。
  已在同一 job 执行 build/staging 时，用 `test:compiled` 与 `test:bun:compiled` 测试该次输出，避免重复编译；
  本地独立运行 `test` / `test:bun` 仍先构建。来源兼容 job 与平台打包并行，但必须全部通过才能发布。
- desktop Facade/transport：增加同级 Flutter package 测试和固定 npm 运行的 `test:flutter-desktop`。
- macOS bundle：先运行 `stage:flutter-macos`，再验证 app 内 `MgReadNode`、Runtime 启动、插件主调用链和子进程退出。
- Android WebView/Javet：增加相邻 Kotlin 单测和目标 Gradle 编译；真实流程仍需用户授权的 Integration Test。
- Windows WebView2：增加 reverse-broker、Dart fake-platform/HTTP 和 Facade reverse-wire fixture；原生修改再
  构建 Windows Debug。不得结束用户正在运行的 `mg_read.exe`。
