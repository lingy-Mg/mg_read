# mg_read_runtime 增量规则

根 `AGENTS.md` 始终适用。本文件只补充 Runtime package 的所有权、任务路由和固定工具链。

## 按任务读取

- Node Core、安装、artifact、协议或插件调用：从目标实现、公开类型、fixture 和直接测试开始。
- Flutter Facade：读 `packages/mgread_plugin_runtime/lib/mgread_plugin_runtime.dart` 及相邻 part/test。
- Node/Javet/ABI 升级：只读 [版本矩阵](docs/runtime-version-matrix.md)的当前选择、平台和待验证部分。
- WebView provider/宿主：读目标平台实现、公开 provider 类型和直接 contract；只有数据源公开能力也变化时
  才加载 `mgread-source-development` 技能的对应 WebView 参考。
- 不同时预加载 Node、Facade、Android、Windows、模板和真实数据源材料。

## Package 所有权

- 本 package 独立拥有 Node Runtime Core、Android Javet、desktop launcher、Supervisor、内部控制/数据面、
  Plugin API、安装、schema/fixture、瞬时诊断和唯一 Flutter Facade。
- 主应用只调用版本化 `PluginRuntime.invoke`；不得获得 executable、PID、端口、ready、bootId、内部 URL、
  wire envelope、Runtime 数据根或平台对象。
- 每个应用进程只有一个 Node Runtime/VM。installed 只在冷启动激活；development 指纹变化先回收旧 VM。
- Runtime 私有数据不得承载书架、目录、正文、进度、书签或主应用设置权威。
- Runtime-only 任务不修改主应用 UI、Reader、模板或真实数据源，除非用户把对应公开边界纳入同一任务。

## 固定工具链与验证

Windows 将 `tools/node-v24.16.0-win-x64` 放到 `PATH` 最前，使用 Node 24.16.0/npm 11.13.0，不回退全局
Node/npm。按受影响边界运行 package scripts 和直接测试；不要机械执行无关平台矩阵。

- Node Core：`npm.cmd run typecheck`、直接 Node 测试、`npm.cmd run check:no-native-addons`。
- desktop Facade/transport：增加相邻 Flutter 测试和 `npm.cmd run test:flutter-desktop`。
- Android WebView/Javet：增加相邻 Kotlin 单测和目标 Gradle 编译；真实流程仍需用户授权的 Integration Test。
- Windows WebView2：增加 reverse-broker、Dart fake-platform/HTTP 和 Facade reverse-wire fixture；原生修改再
  构建 Windows Debug。不得结束用户正在运行的 `mg_read.exe`。
