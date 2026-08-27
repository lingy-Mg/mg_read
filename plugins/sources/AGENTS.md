# 真实书源插件共享开发规则

状态：开发规范。本文件只补充根契约对所有真实 Node 书源共同适用的增量；来源目录自己的
`AGENTS.md` 只写站点差异。只有 capability 跨文件边界不清楚时，才读取
[核心插件内容章节](../../docs/core.md#插件内容-api)中的相关段落，不预加载 Runtime、Flutter 或完整
核心规范。

## 边界与返回值

- 书源使用标准 Node.js 24 开发项目、`package.json.mgread`、lockfile v3 和普通 ESM 开发输出；
  发布默认生成核心规范定义的 single-file artifact。禁止 Worker、子进程、native addon、Git dependency、
  install script、自定义 loader/lock 或主应用/Runtime 内部依赖。
- 生产代码只使用公开 `ctx.http`、`ctx.log`、`ctx.resource`、`ctx.dataDir` 和 `ctx.cacheDir`。
- ID/cursor 是插件作用域的不透明稳定值，URL 只作 metadata。固定键不得缺失；未知可空值显式为
  `null`，集合始终为数组。只修改本次 capability 及其共享解析器，不顺手改变其他返回形状。

## 日志与测试

- capability 只用 `ctx.log` 写有界阶段摘要；HTTP 生命周期由 `ctx.http` 拥有。日志和测试产物不得
  包含 URL/query、搜索词、用户输入、标题、作者、HTML、正文、Cookie、token、凭据、原始异常或
  绝对路径。日志失败不得改变 capability 结果。
- 每次源码变更运行确定性离线测试和 `verify`；请求、选择器、分页或内容解析变化还要运行该来源
  的 `test:live`。线上 smoke 不保存响应 HTML/正文，也不能替代离线回归或 Android artifact 验收。
- 受保护来源只调用公开 `browser.session.v1`；fixture 用注入 provider 模拟验证状态，并断言请求不含
  Cookie/UA。请求必须显式选择 `webview|http` transport 和 `hidden|visible` presentation；`hidden`
  永不转前台，需要人工验证的来源使用可隐藏的 `visible`。fixture 断言所选策略；没有生产 provider 时
  保留 `unsupported`/`interaction_required`，不得静态写入通行数据。
- Windows 命令从来源目录执行，先把
  `../../../packages/mg_read_runtime/tools/node-v24.16.0-win-x64` 放到 `PATH` 最前，禁止回退全局
  Node/npm；随后按 package scripts 运行 `npm.cmd ci`、`npm.cmd test`、`npm.cmd run verify`，以及
  适用的 `npm.cmd run test:live`。
