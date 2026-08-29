# WebView Runtime 与平台宿主开发规范

## 所有权与调用链

```text
数据源 Node VM
  -> PluginWebViewApi / 校验与调用作用域
  -> browser provider 反向请求
     -> Android: Javet bootstrap + 主线程 Android WebView host
     -> Windows: 内部 WS host frame + Flutter host + 原生 WebView2
```

公开层不暴露内部端口、frame、job ID、WebView handle、Profile 路径或原生对象。Windows 和 Android 都以 `pluginId` 作为唯一页面所有者；同一数据源不得出现多个 session key 或多个并存页面。

关键实现位置：

- Runtime API：`packages/mg_read_runtime/src/plugin-webview-page.ts`
- Provider 类型：`packages/mg_read_runtime/src/plugin-browser-session.ts`
- Desktop reverse broker：`packages/mg_read_runtime/src/desktop-browser-session.ts`
- Android bootstrap/contract/host：`AndroidBrowserBootstrap.kt`、`AndroidBrowserSessionContract.kt`、`AndroidBrowserSessionHost.kt`
- Windows Flutter host：`windows_browser_session_host.dart`、`windows_webview_page.dart`
- Windows 原生 host：`windows/windows_browser_host.cpp`、`.h`
- 官方类型投影：`templates/mg_read_plugin_template/src/mgread-api.ts`

## 状态模型

平台宿主必须以同一个状态机为准：

| 当前状态 | 操作 | 结果 |
| --- | --- | --- |
| absent | `open(false)` | 创建 hidden |
| absent | `open(true)` | 创建 visible |
| hidden/visible | `open(...)` | 复用页面并按 visible 请求更新呈现 |
| hidden | `show` | visible |
| visible | `hide` 或用户隐藏 | hidden，页面保留 |
| hidden/visible | `close` 或用户关闭 | absent，取消活动任务并销毁页面 |
| absent | 除 `open/close` 外操作 | `unsupported` |

平台用户按钮与 API 是同一状态转换。原生窗口隐藏/销毁后必须通知 Flutter/Runtime；宿主执行原生输入前还必须直接检查真实窗口可见性，不能只相信缓存布尔值。

## 调度、取消和错误

- 每个页面只有一个普通操作执行槽。Runtime 应使用 FIFO 串行队列，而不是让合法并发调用互相返回 `overloaded`。
- `show/hide/close` 使用独立控制通道，不占普通槽、不受普通 pending 上限阻止；`close` 取消普通槽。
- 每次普通操作拥有 deadline 和 cancel 信号。调用超时后停止轮询、清理宿主 job 和页面结果槽，但保留页面。
- Android bootstrap 使用返回值式 `__mgreadBrowserSessionError` envelope；`browser.session.v1` 和 `ctx.webview` 通过同一个 Runtime 解析器保留稳定错误码。Windows 使用 `WindowsBrowserSessionException`；`PlatformException`、`MissingPluginException` 和 `TimeoutException` 必须先映射为稳定错误再进入 Wire。
- 已知错误不能被 `ignoreResult` 吞掉，也不能在外层 `on Object` 中统一变成 `plugin_execution_failed`。
- 超时后仍可能完成的 Promise 不得向永久全局 Map 写入孤儿结果。使用可取消/过期标记，并在 timeout、cancel、close 和 navigation 时清理。

## JavaScript 结果传输

- 只有 `page.evaluate` 接受数据源任意脚本；HTML、fetch、等待和状态探测均为宿主固定脚本。
- 对 JSON 进行一次明确编码和解码，保留 null、boolean、有限 number、string、array、object。
- 在平台进入内部控制面之前计算 UTF-8 大小。超限应返回稳定有界错误，或通过专用分片/数据面传输；不能依赖 4 MiB WS frame 被动断线。
- 无论成功、失败、超时还是取消，都必须删除对应结果键。结果键不可由来源控制，且不应跨 navigation 保留。
- 不记录脚本正文、返回 JSON、页面 HTML、认证信息或异常原文。

## 宿主 UI

可见页面顶部由宿主绘制，网页不能修改：

1. 标题：`{数据源名称}正在进行探测 - {当前行为}`。
2. 下一行显示当前 URL；导航完成和页面内跳转都应及时刷新。
3. 提供用户可用的隐藏和关闭操作。
4. Windows WebView2 允许 F12 DevTools；Android 不要求对应能力。

标题日志只显示有界行为标签，不显示 URL 查询中的敏感数据、脚本、HTML、Cookie 或响应正文。

## 原生交互

- `click` 接收 CSS viewport 坐标，通过 `devicePixelRatio` 和平台缩放转换后，向目标 WebView 子窗口发送 pointer/touch down/up。
- 坐标必须有限、非负并落在真实内容 viewport；顶部宿主 chrome 不属于坐标空间。
- `inputText` 和 `key` 只作用于目标 WebView 内当前焦点，不允许 OS 全局输入、窗口搜索或焦点抢占其他应用。
- 页面隐藏、被用户关闭或原生窗口不可见时，交互返回 `interaction_required` 或 `unsupported`，不能投递到隐藏页面。

## 越界能力阻止

除 Windows 用户主动 F12 外，探测页面不能越出宿主：

- 只允许主页面导航到 `http/https`；阻止外部协议。
- 禁止新窗口、弹窗、脚本对话框、下载、文件选择、权限请求和全屏窗口。
- Windows 使用原生 WebView2 事件阻止 NewWindow、Permission、Download 和外部 scheme，并原生静音。
- Android 使用 WebChromeClient/WebViewClient 阻止文件选择、权限、新窗口、脚本对话框、下载、外部 scheme 和 custom view。
- 安全要求不能只依赖页面可覆盖或可截断传播的注入脚本。若平台没有原生文件选择或音频阻止能力，必须明确记录未满足，不得宣称“完全禁止”。
- Android 的“需要用户手势才能播放”不等于静音；用户交互后仍能播放的实现不满足完全禁音。

## HTML、fetch 与 Cookie

- `getHtml` 是宿主固定 `outerHTML` 读取，不是原生 DOM getter，也不是来源任意注入。文档和日志必须准确描述。
- `fetch` 在页面执行并遵守 CORS，使用当前浏览器凭据；响应头仅限浏览器暴露的部分。
- 新 API 不读取、枚举、设置或返回 Cookie。旧 `browser.session.v1` 内部 Cookie 行为继续隔离维护，不能泄露到新类型。

## 2026-08-29 已知实现缺口

以下是上次静态审计发现的当前缺口。每次相关任务先重新验证代码；修复后删除对应状态并保留回归测试：

1. Windows 原生隐藏/关闭按钮没有回传 Dart，导致 `visible` 和 session cache 失真；隐藏页面仍可能收到输入，关闭后的 hidden `open` 可能假成功。
2. Node、Android、Windows 都在控制操作前检查全局 pending 上限，`show/hide/close` 不能保证随时执行。
3. Windows `page.*` 提前从 `request()` 返回，绕过旧路径的完整 Platform/MissingPlugin 错误映射。
4. Android 只禁止自动播放，没有完全静音。
5. Windows 文件选择主要由 document 注入脚本阻止，不是不可绕过的原生硬阻断。
6. 新 API 的大型 JS/HTML/fetch 结果缺少受控超限或分片策略，可能超过 Windows 控制帧。
7. `close` 后旧 handle 的行为仍需按状态模型统一，不能由非 `open` 操作静默重建页面；Windows close 也没有稳定取消活动任务。
8. Android/Windows 直接 `JSON.stringify` 页面结果，仍会把 NaN/Infinity/数组内非法值改成 null，或静默丢弃 undefined/function/symbol 字段。
9. Android/Windows 的 `open({visible:false})` 复用可见页面时不会真正隐藏。
10. 导航轮询可能在新文档开始前读取旧页面 readyState；Android 地址栏也没有完整跟随 SPA history URL。
11. Runtime 的单次 `timeoutMs` 在普通操作出队后才启动，不包含 FIFO 排队时间。

不能仅因现有成功路径测试通过就关闭这些缺口。每项至少要有失败前可复现、修复后回归测试和对应平台证据。
