# mgread_plugin_runtime

`mgread_plugin_runtime` 是由本仓库交付的 Flutter-facing Runtime Facade，不是主应用的
Runtime client 实现。应用只调用：

```dart
await runtime.invoke(const RuntimePingInvocation());
```

首次调用由包内 Supervisor 自动启动并验证 Runtime；应用不会获得 Node executable、PID、
端口、ready、bootId、HTTP URL、WebSocket 或 wire envelope。

Windows 上，Supervisor 自己创建带 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job Object 后
才纳管 Node child。应用退出或 Runtime 关闭会由 Windows 内核清理已加入 Job 的 Node 进程树。
Facade 通过 `PluginRuntimeException.code`、异常的 `diagnostics` 和 `runtime.diagnostics` 投影
有界、脱敏的启动/生命周期原因；它们不是 raw stderr、进程控制或 wire API。

生产 `PluginRuntime()` 当前只交付 M1.2 的桌面通信验证 capability
`RuntimePingInvocation`。M1.3 额外有标记为 test-only 的
`TemplatePluginRoundTripInvocation`：它仅在本仓库
`desktopForTesting(enableTemplatePluginFixture: true)` 测试中加载固定空白模板，并验证
插件到 Runtime 的内部服务往返和脱敏日志。它不是通用插件入口，不能注入路径、package、
callback、数据库、Cookie、文件或平台服务。仍没有通用插件系统、书源、Runtime Store、
阅读器数据源、资源流或 Android/Javet 实现。`desktopForTesting` 和 `debug*` 成员仅供本仓库
测试使用，绝不能作为主项目依赖注入接口。

发布 Windows Flutter 包前只由本仓库执行 `npm run stage:flutter-windows`。它把固定 Node
distribution 和编译 Core 放到本 package 的 `assets/runtime/windows-x64/`，生产 Facade 从最终
Flutter 资产目录解析它们；主项目不传入任何路径。

完整边界、测试命令和未验证平台见
[桌面 Runtime 通信闭环](../../docs/desktop-runtime-bridge.md) 和
[空白插件模板](../../docs/plugin-template.md)。
