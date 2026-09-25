# mgread_plugin_runtime 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Flutter Runtime Facade 与平台宿主的所有权和验证入口。

## 按任务读取

- Facade 与 Supervisor：先读 `lib/mgread_plugin_runtime.dart`、目标 part 和相邻测试。
- Android Javet 或私有 Node 进程/WebView：读所选后端的 Kotlin、Dart Supervisor、公开 provider 类型和直接 contract。
- Windows WebView2/Job：读目标 C++ 或 Dart host、reverse-wire fixture 和直接测试。
- Node.js Core、安装、artifact 或内部协议变化：转到同级 `../mg_read_node_runtime/`，读取其最近
  `AGENTS.md`、公开类型与直接测试。

## Package 所有权

- 本 package 独立拥有唯一 Flutter Facade、Supervisor、Android 互斥后端和桌面平台宿主；Node.js Core
  位于同级 `mg_read_node_runtime`，构建后只以 package asset 形式进入本 package。
- 主应用只调用版本化 `PluginRuntime.invoke`；不得获得 executable、PID、端口、ready、bootId、内部 URL、
  wire envelope、Runtime 数据根或平台对象。
- Android 默认使用 Javet；`MGREAD_ANDROID_NODE_PROCESS=true` 在构建期选择 arm64-v8a 私有 Service 中的
  Node 24.21.0。一次应用运行只能启动所选后端，WebView 仍由主进程持有。Runtime 私有数据不得承载主应用持久化权威。
- Windows/Android 的 `MGREAD_NATIVE_RUNTIME=true` 选择独立 Rust Supervisor；与 Android Node 进程开关
  互斥。Windows 同步按该 Dart define 裁剪 Runtime 资产，Android 使用 nativeRuntime source set/dependency。
  私有 Service 只经 Binder 引导 Rust 服务；控制 HTTP 与资源流属于 Rust，不能在 Dart 内新增回环代理。
  原生测试先构建 `tools/build_native_runtime.ps1` 的产物，再执行 native Facade/Android integration；修改
  Kotlin 停止语义必须验证 worker 真正退出后才允许下一次启动。

## 验证

- Dart/Facade：运行目标 Flutter 测试；Node 桌面 transport 变化时追加 Node package 的 `test:flutter-desktop`。
  原生 transport 使用 `test/native_supervisor_test.dart` 和真实原生宿主验收；共享类型需覆盖旧 decoder 测试。
- Android：执行目标 Gradle 编译；原生 Service 的启动、退出与重启需 Integration Test 验证真实进程生命周期，
  不能只用 Kotlin mock 代替。真实流程仍需用户明确授权。
- Windows：增加 reverse-broker、Dart fake-platform/HTTP 和 Facade reverse-wire fixture；原生修改再构建
  Windows Debug，且不得结束用户正在运行的 `mg_read.exe`。
