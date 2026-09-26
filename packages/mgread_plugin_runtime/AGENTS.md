# mgread_plugin_runtime 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Flutter Runtime Facade 与平台宿主的所有权和验证入口。

## 按任务读取

- Facade 与 Supervisor：先读 `lib/mgread_plugin_runtime.dart`、目标 part 和相邻测试。
- Android Javet 或私有 Node 进程/WebView：读所选后端的 Kotlin、Dart Supervisor、公开 provider 类型和直接 contract。
- Windows WebView2/Job：读目标 C++ 或 Dart host、reverse-wire fixture 和直接测试。
- Node.js Core、安装、artifact 或内部协议变化：转到同级 `../mg_read_node_runtime/`，读取其最近
  `AGENTS.md`、公开类型与直接测试。

## Package 所有权

- 本 package 独立拥有唯一 Flutter Facade、Node/原生双 Supervisor、Android 组合后端和桌面平台宿主；Node.js Core
  位于同级 `mg_read_node_runtime`，构建后只以 package asset 形式进入本 package。
- 主应用只调用版本化 `PluginRuntime.invoke`；不得获得 executable、PID、端口、ready、bootId、内部 URL、
  wire envelope、Runtime 数据根或平台对象。
- Android 正常包同时包含 Javet 与 arm64-v8a 私有 Service 中的 Node 24.21.0；设置页保存所选 Node 后端，
  重启 App 进程后生效，默认 Javet。启动组合根必须先初始化 `AndroidNodeRuntimeSettings` 再创建 Facade；
  不支持 arm64 Node 库的设备仅可选择 Javet。Rust 原生后端与所选 Node 后端并存，WebView 仍由主进程持有。Runtime 私有数据
  不得承载主应用持久化权威。
- Windows/Android 默认同时交付 Node 和 Rust 宿主，Facade 按来源引擎归属路由；两种来源 ID 必须全局唯一。
  `MGREAD_NATIVE_RUNTIME=true` 只用于原生独立性验收，该包不提供 Node 切换设置。Windows 按该 define
  裁剪 Node Runtime 资产；Android 正常包用 hybrid source set，独立性验收包用 nativeRuntime source set。
  私有 Service 只经 Binder 引导 Rust 服务；控制 HTTP 与资源流属于 Rust，不能在 Dart 内新增回环代理。
  原生测试先构建 `tools/build_native_runtime.ps1` 的产物，再执行 native Facade/Android integration；修改
  Kotlin 停止语义必须验证 worker 真正退出后才允许下一次启动。
- 区分宿主打包与来源装载：正常 App 预置两套宿主，来源 artifact 可在安装后导入，由归属引擎按需装载；
  不为 Node 和原生来源分别发布正常 App 版本。Node 单文件和原生 DLL/SO 的 artifact、加载与更新规则分别由
  `../mg_read_node_runtime/AGENTS.md` 和 `../mg_read_native_runtime/AGENTS.md` 拥有。

## 验证

- Dart/Facade：运行目标 Flutter 测试；Node 桌面 transport 变化时追加 Node package 的 `test:flutter-desktop`。
  原生 transport 使用 `test/native_supervisor_test.dart` 和真实原生宿主验收；共享类型需覆盖旧 decoder 测试。
- 双引擎并存或按来源路由变化：运行 `test/hybrid_runtime_test.dart`；Android 正常包的实际内容调用另用根目录
  `integration_test/android_hybrid_source_test.dart` 验证，不把单宿主或 native-only 结果当作并存证据。
- Android：执行目标 Gradle 编译；原生 Service 的启动、退出与重启需 Integration Test 验证真实进程生命周期，
  不能只用 Kotlin mock 代替。真实流程仍需用户明确授权。
- Windows：增加 reverse-broker、Dart fake-platform/HTTP 和 Facade reverse-wire fixture；原生修改再构建
  Windows Debug，且不得结束用户正在运行的 `mg_read.exe`。
