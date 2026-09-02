# ctx.webview 公开 API

## 事实入口

- Runtime API 与校验：`packages/mg_read_runtime/src/plugin-webview-page.ts`
- 数据源唯一编译期声明：`packages/mg_read_source_api/index.d.ts`
- Provider 公共类型：`packages/mg_read_runtime/src/plugin-browser-session.ts`
- 引用示例：`packages/mg_read_source_api/README.md`
- 直接测试：`packages/mg_read_runtime/test/webview-page.test.mjs`、
  `browser-session.test.mjs`

字段、参数、返回类型、错误码和上限以共享声明、Runtime 实现与测试为准；本参考只保留使用语义。

## 数据源引用方式

数据源在 `package.json` 的 `devDependencies` 中引用本地 `@mgread/source-api`，在 `.ts`/`.mts` 中只做
类型导入：

```ts
import type {
  MgReadPluginContext,
  PluginWebViewPage,
} from '@mgread/source-api';

export async function activate(context: MgReadPluginContext): Promise<void> {
  const page: PluginWebViewPage = await context.webview.open();
  await page.navigate('https://example.com');
}
```

不要从 `packages/mg_read_runtime/src` 深层导入，也不要保留来源自己的 Context/WebView 子集；否则新增
能力（例如 `cdp`、`click`、`inputText`、`key`、`close`）不会在来源编译期可见。

## 页面与生命周期

- 每个 pluginId 只有一个宿主持有的页面。`open` 创建或复用，`navigate` 更新页面，`show/hide` 只改变
  可见性，`close` 才销毁。关闭后只有 `open` 可以重建。
- 普通操作按页 FIFO；`show/hide/close` 走控制旁路，`close` 取消活动操作。超时或取消清理 job 和结果，
  但不因普通失败销毁可复用页面。
- `evaluate` 执行来源脚本；HTML、fetch、等待和 URL 查询由宿主固定实现。JSON 结果必须保留合法类型并
  稳定拒绝不可序列化或超限值，不能静默丢字段或改成 null。
- `fetch` 在当前页面上下文执行、遵守 CORS 并携带浏览器凭据；来源只能看到浏览器公开的响应信息。

## 安全与人工交互

- API 不提供 `sessionKey`、Cookie getter/setter、原生对象、窗口句柄、内部 job ID 或 wire envelope。
- 禁止用 `evaluate` 注入点击、设置 input value、提取/回放挑战 token 或绕过验证。
- 原生 `click/inputText/key` 只作用于可见目标 WebView；隐藏、关闭或不可见时返回
  `interaction_required` 或 `unsupported`，不得退化为 OS 全局输入。
- 日志不得包含脚本、HTML、JSON 返回、Cookie、认证信息、URL 查询或挑战内容。

## 最小验证

使用固定 Node 运行 Runtime typecheck 和 `webview-page`、`browser-session` 直接测试。覆盖单页复用、状态
转换、FIFO/控制旁路、取消/超时/close、合法 JSON、非法值、大小边界、CORS fetch、稳定错误和无 Cookie API。
只有 provider 或原生宿主变化时才增加平台参考和平台测试。
