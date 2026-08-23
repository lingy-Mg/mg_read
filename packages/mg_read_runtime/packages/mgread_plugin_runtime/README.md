# mgread_plugin_runtime

`mgread_plugin_runtime` 是 MgRead 唯一 Flutter-facing Runtime Facade。应用调用强类型
invocation，不会获得 Node executable、PID、端口、ready、bootId、HTTP URL、WebSocket 或
wire envelope。

```dart
final runtime = PluginRuntime();
final ping = await runtime.invoke(const RuntimePingInvocation());
final plugins = await runtime.invoke(const InstalledPluginsInvocation());
final sourceDirectoryKind = await runtime.invoke(
  const OpenPluginCodeDirectoryInvocation(
    pluginId: 'org.example.source',
  ),
);
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
final discovery = await runtime.invoke(
  const SourceDiscoverInvocation(pluginId: 'org.example.source'),
);

// Opens the native Windows or Android picker, accepts one `.mgplugin`,
// installs it through the Runtime-owned inbox, cold-activates it, and returns
// false when the user cancels.
final imported = await runtime.importLocalPlugin();
final detail = await runtime.invoke(
  const SourceDetailInvocation(
    pluginId: 'org.example.source',
    id: 'book-1',
  ),
);

final events = await runtime.invoke(
  const RuntimeDiagnosticsEventsInvocation(),
);
final capture = await runtime.invoke(
  RuntimeDiagnosticsCaptureStartInvocation(
    payloadKind: RuntimeDiagnosticPayloadKind.contentPayload,
    detailStorage: RuntimeDiagnosticDetailStorage.memoryOnly,
    duration: const Duration(minutes: 15),
    maxStoredBytes: 8 * 1024 * 1024,
    components: const <String>{'runtime.http', 'runtime.plugin'},
  ),
);
await runtime.invoke(RuntimeDiagnosticsCaptureStopInvocation(capture.sessionId));
```

内容类型不猜默认值：协议中每个 nullable 键都必须存在并编码为具体值或 JSON `null`，集合固定
为数组且无值时返回 `[]`，非负计数中的 `0` 保留为真实零值。缺键、`undefined`、空白字符串、
错误枚举或把数组写成 `null` 都会被 Runtime/Facade 拒绝为稳定格式错误。

诊断 Facade 只返回稳定 ID、cursor、受控字段和最大 32 KiB 的 range chunk。默认 Runtime 日志
仅写关键元数据 TXT；上述显式 capture 才允许详情进入有界内存，只有
`persistToText` 会创建独立详情 TXT。

首次调用由 package 内 Supervisor 自动启动固定 Runtime；生产构造器不接受数据根、Node 路径
或主项目 callback。Windows Supervisor 先创建带
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Runtime-owned Job Object，再启动并纳管 Node child。
Facade 将失败投影为稳定 `PluginRuntimeException.code` 和有界诊断，不转发 raw stderr、路径、
插件文本或进程控制。

`PluginRuntime.desktopForTesting` 与 `debug*` 成员只用于本仓库 testkit。测试专用临时 data
root 用来预置标准插件版本，不是生产依赖注入接口，也不能由主项目调用。

`importLocalPlugin()` 是生产 Facade 的本地数据源导入能力。文件选择器、私有 inbox、原子复制、
`.mgplugin` 校验和冷激活均由本 package/Runtime 负责；主应用只接收取消或成功结果，不接触文件路径。
Windows 通过受管 Node 子进程重启完成冷激活，Android 通过专用 Javet 线程有序停止并重建唯一活动
Runtime 实例完成冷激活。

发布 Windows package 前由 Runtime 仓库执行 `npm run stage:flutter-windows`，把固定
`node.exe`、Node LICENSE 和编译 Core 放入本 package 的递归资产布局。Android Javet、macOS 和最终应用包内
运行需要各自验收，desktop 源码测试不替代这些门禁。

Windows Debug 由本 package 在仓库内解析 `plugins/sources` 并把该内部目录交给 Runtime；书源
项目不复制进 assets。package/lock 或已构建输出变化后，Facade 在下一次调用前回收旧 Node/VM，
再启动唯一的新 Runtime。Release 不启用该路径。

`OpenPluginCodeDirectoryInvocation` 仅在 Windows 桌面端由 Runtime 打开目录：development 结果
打开工作区项目，安装来源打开当前 immutable version 副本。Facade 只返回这两种类型，绝不返回
绝对路径；安装副本不是即时开发加载入口。

源码环境的 Facade 冷启动/热调用基线可从本目录运行：

```powershell
flutter test test/facade_performance_test.dart --reporter expanded
```

完整边界见[桌面 Runtime 与标准插件闭环](../../docs/desktop-runtime-bridge.md)。
