# mgread_plugin_runtime

Runtime-owned Flutter Facade 与 Android/Windows 平台宿主。Flutter 主应用只通过此 package 的公开入口调用
版本化 Runtime 能力。

```dart
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
```

公开类型和调用以 [`lib/mgread_plugin_runtime.dart`](lib/mgread_plugin_runtime.dart) 为准。使用方不得依赖
内部 part、PID、端口、WebSocket、Runtime 路径或平台对象，也不得向 Runtime 注入主应用数据库和文件服务。

版本与平台选择见 [`../../docs/runtime-version-matrix.md`](../../docs/runtime-version-matrix.md)，开发规则见
[`../../AGENTS.md`](../../AGENTS.md)。
