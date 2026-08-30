# WebView Runtime 与平台宿主

## 事实入口

- Runtime provider/broker：`plugin-browser-session.ts`、`desktop-browser-session.ts`
- Android：`AndroidBrowserBootstrap.kt`、`AndroidBrowserSessionContract.kt`、
  `AndroidBrowserSessionHost.kt`
- Windows Flutter：`windows_browser_session_host.dart`、`windows_webview_page.dart`
- Windows native：`windows/windows_browser_host.cpp` 与头文件
- 直接测试：`desktop-browser-session.test.mjs`、`windows_browser_session_host_test.dart`、
  `AndroidBrowserSessionContractTest.kt`

先定位目标平台和状态转换，不预加载另一平台实现。

## 共同状态机

| 状态 | 操作 | 结果 |
| --- | --- | --- |
| absent | `open(visible)` | 创建 hidden 或 visible |
| hidden/visible | `open(visible)` | 复用页面并应用请求的可见性 |
| hidden | `show` | visible |
| visible | `hide` 或 Windows 用户关闭窗口 | hidden，页面保留 |
| hidden/visible | `close` | absent，取消任务并销毁 |
| absent | 除 `open/close` 外操作 | `unsupported` |

同一 pluginId 不能有多个 session/page。平台状态、Runtime cache 和真实窗口可见性必须一致。

## 调度、传输与原生边界

- 每页一个普通 FIFO；控制操作不受普通 pending 阻塞。`close` 必须取消普通槽。
- deadline 包含排队与执行；timeout/cancel/navigation/close 都清理结果键，迟到 Promise 不能写入永久表。
- JSON 明确编码一次并在进入控制面前检查 UTF-8 大小；超限稳定失败或走专用数据面，不能靠 WS 断线限流。
- 原生输入转换 CSS viewport 坐标并严格限制在可见内容区；文本和按键只发送到目标 WebView 当前焦点。
- 宿主原生阻止新窗口、外部协议、下载、文件选择、权限、对话框和全屏；静音能力必须由真实平台证据证明。
- Windows 用户关闭窗口只隐藏；脚本 `close` 才销毁。Windows 允许用户主动 F12，但代码和测试不用 CDP。
- Android multi-profile 不可用时明确记录 `single_fallback`，不得宣称跨插件 Cookie 隔离。

## 最小验证

- Runtime/broker：固定 Node typecheck、`desktop-browser-session` 和相关 contract。
- Windows Flutter：相邻 fake-platform/HTTP、browser host 和 reverse-wire 测试；native 变化再构建 Windows Debug。
- Android：目标 Kotlin 单测与 Gradle 编译；真实页面只在用户授权后通过允许设备的 Integration Test。
- 真实验收分别检查显隐/关闭、输入、导航、错误、禁用越界能力、静音和资源清理。Windows 证据不替代 Android。
