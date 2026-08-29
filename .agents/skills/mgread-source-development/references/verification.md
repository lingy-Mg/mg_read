# 数据源、发现组合与 WebView 验证规范

## 验证分层

报告中必须分开以下证据：

1. 类型检查和静态检查。
2. Node/Flutter/Kotlin/C++ 自动化测试。
3. 数据源 fixture 和 CLI 网络 smoke。
4. Codex 内置浏览器中的真实网页结构、选择器和路由取证。
5. artifact 构建、校验、冷安装与激活。
6. Windows 真实 WebView2。
7. Android 授权设备上的真实 WebView。
8. 未执行项和外部阻塞。

任何一层都不能替代另一层。CLI smoke 不证明渲染后页面结构；Codex 内置浏览器不证明 MgRead WebView
的 Cookie/Profile、窗口或平台行为；Fake platform 通过不证明原生窗口状态、真实输入、静音、文件选择
或 F12；Windows 通过不证明 Android。

## 数据源默认检查

在目标数据源插件目录使用仓库固定 Node 24，按其 `AGENTS.md` 和 scripts 运行：

```powershell
npm.cmd ci
npm.cmd test
npm.cmd run verify
```

线上选择器、页面层级、分页、跳转或验证后结构变化时，先按
[真实网页浏览器探测](real-page-browser-probing.md)使用 Codex 内置浏览器确认实际页面，再运行明确存在的
`test:live` 作为网络 smoke。不要把 CLI 返回内容当作浏览器 DOM，不要把临时网络失败写成规则成功，
也不要用线上响应覆盖脱敏 fixture。

构建实际声明的 artifact 模式，并验证：

- 文件名、descriptor、版本、代码长度和 SHA-256。
- single-file 不含 node_modules/源码/sidecar；archive 保留 lock 恢复语义。
- 在临时 Runtime 数据根中冷安装并激活；不能只 import 工作区 `dist`。

## 发现跨层检查

- Runtime 组件类型或校验变化：使用固定 Node 运行 Runtime 类型检查和直接 contract 测试；只有触及 desktop Facade/reverse wire 时再增加 `test:flutter-desktop`。
- Flutter Facade/decoder 变化：运行 package 相邻测试和定向 analyze。
- 主应用发现 UI 变化：只实际格式化任务拥有的 Dart 文件，运行最近的 widget/golden 测试并查看生成图片；再按根 `AGENTS.md` 执行格式检查和 `flutter analyze`。
- 真实来源发现输出和官方模板：在各自目录运行声明的 `npm.cmd run verify`。纯组件/图标投影变化不需要冒充 live 网络验证；请求、选择器、分页或解析变化才运行显式 `test:live`。
- 根 Flutter 生产代码或用户可见资源变化完成后，只通过 `tools/update_flutter_version.ps1` 按任务规模更新一次版本；纯技能、文档、Runtime package、模板或独立来源变化不升级根版本。

## Runtime Node 检查

把 `packages/mg_read_runtime/tools/node-v24.16.0-win-x64` 放在 PATH 最前，不回退全局 Node：

```powershell
npm.cmd ci
npm.cmd run typecheck
npm.cmd test
npm.cmd run check:no-native-addons
```

WebView API 至少覆盖：

- 单页复用、无 `sessionKey`、无 `onUrlChanged`、无 Cookie API。
- 所有合法 JSON 类型、异步 resolve/reject、不可 JSON 化值、NaN/Infinity、超限值。
- Android 返回值式错误 envelope 对每个稳定错误的映射；控制方法不得假成功。
- 普通操作 FIFO、控制通道在活动任务和全局容量下仍可 show/hide/close。
- timeout/cancel/close 不销毁页面但清理 job 和结果槽；close 后只有 open 能重建。
- 非法 URL、坐标、按键、timeout 和响应形状。

## Windows 检查

在 `packages/mg_read_runtime/packages/mgread_plugin_runtime` 运行相邻 Flutter 测试，并根据 Runtime `AGENTS.md` 运行 desktop reverse-wire fixture。原生变更必须执行：

```powershell
flutter build windows --debug
```

如果 `mg_read.exe` 正在占用链接输出，不得擅自结束用户进程。报告锁定并等待授权或由用户关闭后重试。

真实 WebView2 验收至少检查：

- 系统窗口标题显示数据源名称和当前行为，页面内顶部只显示当前 URL。
- 页面内没有隐藏和关闭按钮；标题栏关闭、Alt+F4 和任务栏关闭只隐藏并保留页面，只有脚本 `close` 销毁。
- API hide/show 与用户关闭隐藏状态一致；脚本关闭后 open 能重建。
- 隐藏页面不能接收 pointer、文本或按键。
- 新窗口、外部协议、下载、权限、脚本对话框、文件选择、全屏和音频确实被阻止。
- F12 能打开 DevTools，但代码和测试不使用 CDP。
- 导航、异步 JS JSON、实时 HTML、CORS fetch、waitForText 和超时后复用。
- PlatformException/MissingPlugin/timeout/cancel 保留稳定错误码。

## Android 检查

WebView 宿主变更至少运行：

```powershell
.\gradlew.bat :mgread_plugin_runtime:compileDebugKotlin :mgread_plugin_runtime:testDebugUnitTest
```

命令从仓库 `android` 目录执行。真实页面和跨层流程仅在用户明确授权后使用根 `AGENTS.md` 允许的已连接设备和 Integration Test；不得启动、控制或重置设备，也不得使用坐标式 adb 输入或系统截图代替 Flutter 测试语义。

Android 真实验收至少检查：

- hidden 不附着 View，visible 只有一个前台探测弹窗。
- 用户隐藏/关闭与 Runtime 状态一致，关闭取消活动操作。
- native touch、InputConnection 文本和 KeyEvent 只作用于可见目标 WebView。
- 文件选择、权限、新窗口、下载、对话框、外部 scheme 和 custom view 被阻止。
- 音频完全不可播放；仅禁止 autoplay 不能通过这一项。
- multi-profile 支持时隔离；不支持时记录 `single_fallback`，不能宣称跨插件 Cookie 隔离。
- Javet polling 的成功、错误 envelope、取消、超时和结果清理。

## WebView 缺陷回归矩阵

每个已知缺口的修复都要增加能在旧实现失败的测试：

| 缺口 | 最低回归证据 |
| --- | --- |
| Android 错误假成功 | Provider 返回每个 error envelope，所有 API 拒绝并保留 code |
| JS 返回值失真 | 真实宿主序列化拒绝 NaN/Infinity/undefined/function/symbol，不能静默改成 null 或丢键 |
| Windows 手动隐藏失真 | 模拟标题栏关闭，Dart 状态更新；窗口只隐藏且页面保留；隐藏输入被拒绝 |
| 控制通道被 pending 阻塞 | 普通任务占满时 show/hide/close 仍完成，close 取消任务 |
| Windows 错误降级 | 原生 Platform/MissingPlugin/timeout 分别映射稳定 code |
| 异步结果泄漏 | Promise 在 timeout/cancel 后完成，结果表仍为空 |
| HTML 语义不准确 | API/模板/核心规范统一称宿主固定实时 DOM 读取 |
| Android 未静音 | 用户交互后媒体仍不能产生音频 |
| Windows 文件选择可越出 | 恶意页面阻止事件传播或调用 picker 也不能弹出系统窗口 |
| 大结果断线 | 边界内成功，边界外稳定失败或分片，控制连接保持可用 |
| 打开和导航状态 | open(false) 隐藏复用页；导航不能读取旧文档 readyState；地址栏跟随 SPA URL |
| 并发、超时和 close 生命周期 | 普通操作顺序稳定；timeout 包含排队；close 后非 open 操作为 unsupported |

## 完成判定

只有公开契约、两端 provider、平台状态机、错误语义、模板、开发文档、回归测试和任务要求的平台真实证据一致时，才可以说“全部完成”。Cookie 明确排除时不计入完成范围，但旧 Cookie 能力也不能被误删或暴露到新 API。
