# mgread_plugin_runtime 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Flutter Runtime Facade 与平台宿主的所有权和验证入口。

## 按任务读取

- Facade 与 Supervisor：先读 `lib/mgread_plugin_runtime.dart`、目标 part 和相邻测试。
- Android Javet/WebView：读目标 Kotlin 实现、公开 provider 类型和直接 contract。
- Windows WebView2/Job：读目标 C++ 或 Dart host、reverse-wire fixture 和直接测试。
- Node.js Core、安装、artifact 或内部协议变化：转到同级 `../mg_read_node_runtime/`，读取其最近
  `AGENTS.md`、公开类型与直接测试。

## Package 所有权

- 本 package 独立拥有唯一 Flutter Facade、Supervisor、Android Javet 和桌面平台宿主；Node.js Core
  位于同级 `mg_read_node_runtime`，构建后只以 package asset 形式进入本 package。
- 主应用只调用版本化 `PluginRuntime.invoke`；不得获得 executable、PID、端口、ready、bootId、内部 URL、
  wire envelope、Runtime 数据根或平台对象。
- 每个应用进程只有一个 Node Runtime/VM。Runtime 私有数据不得承载主应用持久化权威。

## 验证

- Dart/Facade：运行目标 Flutter 测试；桌面 transport 变化时追加 Node package 的 `test:flutter-desktop`。
- Android：增加相邻 Kotlin 单测和目标 Gradle 编译；真实流程仍需用户明确授权的 Integration Test。
- Windows：增加 reverse-broker、Dart fake-platform/HTTP 和 Facade reverse-wire fixture；原生修改再构建
  Windows Debug，且不得结束用户正在运行的 `mg_read.exe`。
