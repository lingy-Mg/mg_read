# mgread_plugin_runtime

`mgread_plugin_runtime` 是 MgRead 唯一 Flutter-facing Runtime Facade。应用调用强类型
invocation，不会获得 Node executable、PID、端口、ready、bootId、HTTP URL、WebSocket 或
wire envelope。

```dart
final runtime = PluginRuntime();
final ping = await runtime.invoke(const RuntimePingInvocation());
final plugins = await runtime.invoke(const InstalledPluginsInvocation());
final exportable = await runtime.invoke(const PluginTransferListInvocation());
final plan = await runtime.invoke(PluginTransferPlanInvocation(artifacts: exportable));
final sourceDirectoryKind = await runtime.invoke(
  const OpenPluginCodeDirectoryInvocation(
    pluginId: 'org.example.source',
  ),
);
await runtime.invoke(const OpenRuntimePrivateDirectoryInvocation());
final cacheUsage = await runtime.invoke(const PluginCacheUsageInvocation());
final cleared = await runtime.invoke(
  const ClearAllPluginCachesInvocation(),
);
final results = await runtime.invoke(
  const SourceSearchInvocation(
    pluginId: 'org.example.source',
    query: '示例',
  ),
);
final suggestions = await runtime.invoke(
  const SourceSearchSuggestionsInvocation(
    pluginId: 'org.example.source',
  ),
);
final discovery = await runtime.invoke(
  const SourceDiscoverInvocation(pluginId: 'org.example.source'),
);

// Opens the native Windows or Android picker, accepts one `.mgplugin.js` or
// `.mgplugin`,
// installs it through the Runtime-owned inbox, cold-activates it, and returns
// false when the user cancels.
final imported = await runtime.importLocalPlugin();
final detail = await runtime.invoke(
  const SourceDetailInvocation(
    pluginId: 'org.example.source',
    id: 'book-1',
  ),
);

```

Plugin transfer v2 is Runtime-owned and bounded: each single-file or archive
artifact is at most 32 MiB, and each batch is at most 32 artifacts and 512 MiB.
Artifact metadata is path-free; export returns the retained artifact as an
ephemeral byte stream and import preserves its bytes and format, verifies the
declared size and SHA-256 in the package-owned adapter, then performs one cold
activation. LAN transfer converts a Debug development project into a temporary
`devsync` version only on explicit send; Windows Debug
`packageDevelopmentPlugin()` instead lets the user select an output directory,
builds the project at its declared version, and returns only the safe artifact
file name. Equal installed versions and downgrades remain excluded.

内容类型不猜默认值：协议中每个 nullable 键都必须存在并编码为具体值或 JSON `null`，集合固定
为数组且无值时返回 `[]`，非负计数中的 `0` 保留为真实零值。缺键、`undefined`、空白字符串、
错误枚举或把数组写成 `null` 都会被 Runtime/Facade 拒绝为稳定格式错误。

Runtime 不再发布结构化诊断事件、capture 或历史查询 Facade，也不创建 `diagnostics/events`
分段文件。Debug 检查页只保留进程内有界实时日志尾部；Supervisor 继续提供少量稳定启动/终止
诊断，不保存插件正文、HTTP body 或复杂事件对象。

首次调用由 package 内 Supervisor 自动启动固定 Runtime；生产构造器不接受数据根、Node 路径
或主项目 callback。Windows Supervisor 先创建带
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Runtime-owned Job Object，再启动并纳管 Node child。
Facade 将失败投影为稳定 `PluginRuntimeException.code` 和有界诊断，不转发 raw stderr、路径、
插件文本或进程控制。

`fatalDiagnostics` 只发布 Node 启动失败或意外退出等终端 Runtime 状态，供应用显示全局 fatal
提示；它仍只含稳定 code 和安全文案。ready 前尚不存在 Node TXT diagnostics 时，Supervisor 在
Runtime 私有根写入 16 KiB 封顶的 `desktop-fatal-fallback.txt`，其中仅有 code、phase、opaque
fingerprint 和耗时，不含路径、stderr、异常、请求或插件数据。不会自动重试；仅下一次显式
capability 调用会有序冷启动唯一 Runtime。

`PluginRuntime.desktopForTesting` 与 `debug*` 成员只用于本仓库 testkit。测试专用临时 data
root 用来预置标准插件版本，不是生产依赖注入接口，也不能由主项目调用。

`browser.session.v1` 在 Android 由 Javet/WebView provider 实现，在 Windows 由内部 WS 反向帧进入
package 自有 WebView2；两者都不增加主应用 Facade。`transport=webview` 在同源页面内运行宿主固定
`fetch`；`transport=http` 从独立 Profile/UDF 内部读取 Cookie/UA 后由宿主直连并回写 Set-Cookie。
每个插件最多一个 WebView；可见验证使用全局唯一弹窗并可隐藏，隐藏会话不显示。Android 缺少
multi-profile 或 Windows 缺少 Evergreen WebView2 Runtime 时返回 `unsupported`，不会共享默认会话。

`importLocalPlugin()` 是生产 Facade 的本地数据源导入能力。文件选择器、私有 inbox、原子复制、
`.mgplugin.js` / `.mgplugin` 校验和冷激活均由本 package/Runtime 负责；主应用只接收取消或成功结果，
不接触文件路径。
Windows 通过受管 Node 子进程重启完成冷激活，Android 通过专用 Javet 线程有序停止并重建唯一活动
Runtime 实例完成冷激活。

发布 Windows package 前由 Runtime 仓库执行 `npm run stage:flutter-windows`，把固定
`MgReadNode.exe`、Node LICENSE 和编译 Core 放入本 package 的递归资产布局；该文件是原 Node
二进制的改名副本，不使用 PATH 或全局 Node。Android Javet、macOS 和最终应用包内
运行需要各自验收，desktop 源码测试不替代这些门禁。

Windows Debug 由本 package 在仓库内解析 `plugins/sources` 并把该内部目录交给 Runtime；书源
项目不复制进 assets。package/lock 或已构建输出变化后，Facade 在下一次调用前回收旧 Node/VM，
再启动唯一的新 Runtime。同一插件 ID 同时存在开发项目和已安装包时，只加载并展示开发项目；
已安装包保留为移除开发项目后的冷启动回退，不会并行执行或写入同一插件私有状态。Release 不启用该路径。

`OpenPluginCodeDirectoryInvocation` 仅在 Windows 桌面端由 Flutter Supervisor 打开目录：Runtime
只负责解析 development 工作区项目或当前 immutable version 副本，随后由 Flutter owner 在
Node Job Object 外启动 Explorer。Facade 只返回这两种类型，绝不返回绝对路径；安装副本不是
即时开发加载入口。

`OpenRuntimePrivateDirectoryInvocation` 仅在 Windows 由 Flutter desktop Supervisor 打开 Runtime
私有数据根，不让受 Job Object 管理的 Node child 创建 Explorer；Facade 不返回路径；Android 返回稳定的
`unsupported` 错误。

源码环境的 Facade 冷启动/热调用基线可从本目录运行：

```powershell
flutter test test/facade_performance_test.dart --reporter expanded
```

完整边界见[桌面 Runtime 与标准插件闭环](../../docs/desktop-runtime-bridge.md)。
