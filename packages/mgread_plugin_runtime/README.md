# mgread_plugin_runtime

Runtime-owned Flutter Facade 与 Android/Windows 平台宿主。Flutter 主应用只通过此 package 的公开入口调用
版本化 Runtime 能力。

```dart
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
```

公开类型和调用以 [`lib/mgread_plugin_runtime.dart`](lib/mgread_plugin_runtime.dart) 为准。使用方不得依赖
内部 part、PID、端口、WebSocket、Runtime 路径或平台对象，也不得向 Runtime 注入主应用数据库和文件服务。
有页面请求世代的调用方可向 `PluginRuntime.invoke` 传入 `PluginInvocationCancellation`；同一个实例可覆盖
并行详情/目录请求，desktop 与 Android 都会把取消继续传入 Runtime 的 `AbortSignal`。

Node.js Core 位于同级 [`mg_read_node_runtime`](../mg_read_node_runtime/README.md)。版本与平台选择见
[`runtime-version-matrix.md`](../mg_read_node_runtime/docs/runtime-version-matrix.md)，开发规则见
[`AGENTS.md`](AGENTS.md)。
