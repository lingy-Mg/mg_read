# `ctx.webview` 数据源 API 规范

## 目标和边界

`ctx.webview` 为每个数据源提供唯一、由宿主持有的浏览器页面。它用于真实页面导航、异步 JavaScript、浏览器上下文请求、实时 DOM、人工验证以及 WebView 原生输入。

- 重复 `open()` 返回同一逻辑 page handle，不创建 `sessionKey`。
- 新接口不提供 `onUrlChanged` 或 Cookie API。使用 `getUrl()` 主动读取地址；Cookie 始终留在平台宿主。
- 不使用 CDP。Windows 仅允许用户按 F12 打开 WebView2 DevTools。
- 默认隐藏，只有显式 `visible: true` 或 `show()` 才显示。

```ts
const page = await ctx.webview.open({ visible: true });
await page.navigate('https://example.com/');
const result = await page.executeJavaScript<{ title: string }>(`
  await Promise.resolve();
  return { title: document.title };
`);
```

## 页面生命周期

规范状态为 `absent -> hidden/visible -> closed(absent)`：

- `open({visible:false})` 创建或复用隐藏页面；`open({visible:true})` 创建或复用并显示。
- `show()` 和 `hide()` 只改变呈现状态，不清除导航、DOM、Storage 或浏览器会话。
- `close()` 销毁平台页面并取消活动普通操作。之后只有再次 `open()` 才能重新创建；旧 handle 的其他方法应返回 `unsupported`，不能静默重建。
- Windows 宿主不提供页面内隐藏或关闭按钮；用户触发系统标题栏关闭、Alt+F4 或任务栏关闭时只隐藏窗口并保留页面。只有数据源脚本调用 `close()` 才销毁页面。Android 宿主的用户隐藏/关闭操作继续分别映射为 `hide()`/`close()`。
- 超时或取消单个普通操作不销毁页面，后续操作仍可继续。

普通操作按数据源串行执行。`show/hide/close` 属于独立控制通道：必须能在普通操作等待、超时或页面验证期间执行，不能被普通请求队列和容量上限阻塞；`close` 可以取消活动操作。

## JavaScript 与 JSON

```ts
executeJavaScript<T extends JsonValue>(
  code: string,
  options?: { timeoutMs?: number },
): Promise<T>
```

- `code` 是异步函数体，不是表达式，因此允许顶层 `await` 和 `return`。
- 宿主不限制脚本内容，也不按字段过滤返回 JSON；页面自身的浏览器安全模型仍然生效。
- 返回值必须是 JSON 值：`null`、boolean、有限 number、string、JSON array 或纯 JSON object。
- `undefined`、function、symbol、BigInt、循环引用以及不能稳定 JSON 序列化的结果必须失败；`NaN` 和 Infinity 不能作为合法 number 悄悄变成 `null`。
- 脚本正文当前最大 512 KiB，调用超时为 1 至 120000 ms，默认 30000 ms。大型结果必须由宿主给出稳定超限错误或采用有界传输，不能让内部控制连接断开。
- 页面抛错、Promise reject 或 JSON 序列化失败统一为 `plugin_execution_failed`，不能泄露页面异常原文。

## 函数清单

### `open(options?)`

创建或复用唯一页面，返回稳定 page handle。`visible` 默认 false；没有 `sessionKey`。

### `navigate(url, options?)`

导航到绝对 `http` 或 `https` URL，并等待主文档进入 `interactive` 或 `complete`。重定向后的地址用 `getUrl()` 获取。外部协议必须被宿主阻止。

### `executeJavaScript(code, options?)`

在当前页面执行上述异步函数体并返回任意合法 JSON 值。它是唯一允许数据源提供任意页面脚本的函数。

### `getHtml(options?)`

返回当前渲染完成状态下的 `document.documentElement.outerHTML`，包含客户端 DOM 修改。

当前 Android WebView 和 WebView2 没有满足本项目边界的直接原生 DOM 字符串读取接口；在不使用 CDP 的前提下，实现应描述为“宿主固定脚本读取实时 DOM”，而不是“原生直读 HTML”。数据源不提供这段固定脚本。

### `fetch(request)`

```ts
interface WebViewFetchRequest {
  url: string;
  method?: string;
  headers?: Readonly<Record<string, string>>;
  body?: string | null;
  responseType?: 'text' | 'json' | 'base64';
  timeoutMs?: number;
}
```

宿主在当前页面中执行 `window.fetch`，固定使用 `credentials: 'include'` 和 `redirect: 'follow'`：

- 自动使用页面可用的 Cookie、认证和浏览器网络栈，但不向数据源暴露 Cookie。
- 完整遵守浏览器 CORS、mixed-content 和 forbidden-header 规则，不提供宿主 HTTP 绕过。
- 返回 `{status,url,headers,body}`；headers 只能包含浏览器允许脚本读取的响应头。
- `responseType:'json'` 返回 JSON 值，`text` 返回字符串，`base64` 返回字符串。
- 无界响应必须在进入内部控制面前被限制或分片，并返回稳定错误。

### `click({x,y,timeoutMs?})`

- 坐标是相对 WebView 内容 viewport 的 CSS 像素，不包含 Windows 宿主地址栏或 Android 宿主顶部区域。
- 页面必须可见；隐藏页面返回 `interaction_required`。
- 宿主把坐标转换为平台输入坐标并发送真实 WebView pointer/touch 输入。
- 禁止 `HTMLElement.click()`、DOM `dispatchEvent()`、CDP 和桌面全局点击。

### `inputText(text, options?)`

向当前已聚焦的页面控件发送平台原生文本输入。页面必须可见；函数不负责用 DOM 选择器寻找或设置控件。通常先用 `click()` 聚焦目标。

### `key(request)`

支持 `Enter/Tab/Escape`、四个方向键、`PageUp/PageDown/Home/End/Backspace/Delete`，可组合 `alt/control/shift`。通过平台 WebView 输入入口发送，页面必须可见。

### `waitForText(request)`

```ts
await page.waitForText({
  text: '验证成功',
  scope: 'text', // 或 'html'
  timeoutMs: 60_000,
});
```

- `timeoutMs` 必填，禁止无期限等待。
- `scope:'text'` 检查实时 `innerText`，`scope:'html'` 检查实时 `outerHTML`。
- 匹配后立即返回 `{url}`，适合用户完成验证后继续流程。
- 超时只终止等待，不关闭页面。

### `getUrl(options?)`

主动返回当前 `location.href`。新接口没有 URL 变化回调。

### `show(options?)`、`hide(options?)`

随时显示或隐藏唯一页面。它们属于控制通道，不能因为普通页面操作正在执行而返回 `overloaded`。

### `close(options?)`

销毁页面和宿主窗口，取消活动操作并释放浏览器资源。重新使用必须先调用 `open()`。

## 稳定错误

平台和传输必须保留这些语义：

- `cancelled`：调用作用域或页面关闭取消。
- `interaction_required`：隐藏状态不能完成原生交互，或需要用户显示页面处理。
- `overloaded`：有界资源确实耗尽；不能用于普通串行冲突或控制通道。
- `plugin_execution_failed`：页面脚本、平台调用或不可分类执行失败。
- `timeout`：调用达到最大等待时间；页面保持可复用。
- `unsupported`：平台能力不存在、页面未打开或已关闭。

Runtime 自身还可以在进入宿主前返回 `invalid_request`，并在宿主响应不符合公开类型时返回 `plugin_invalid_response`。Android 返回值式错误 envelope 和 Windows 异常必须映射为相同错误，禁止把已知错误降级成假成功或通用失败。

## 禁止模式

- 不得新增 `sessionKey`、Cookie getter/setter 或 `onUrlChanged`。
- 不得从 `document.cookie` 推断已经取得全部 Cookie。
- 不得通过 `executeJavaScript` 模拟用户点击、设置 input value 或绕过站点验证；需要可信交互时使用平台原生输入。
- 不得依赖窗口句柄、WebView2 controller、Android `WebView` 对象、内部 job ID、轮询全局变量或 WS envelope。
- 不得把网页 HTML、JS 返回值、认证头、Cookie 或挑战内容写入日志。
