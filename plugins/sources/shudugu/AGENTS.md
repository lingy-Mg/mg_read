# 速读谷书源开发约束

根 `../../../AGENTS.md` 和插件内容契约适用。本目录是标准 Node.js 24 书源，不是 Runtime 或 Flutter
功能；生产代码只能使用公开的 `ctx.http`、`ctx.log`、`ctx.dataDir` 和 `ctx.cacheDir`。

每次修改来源解析、请求、内容字段或缓存后，必须使用固定 Node 24.16.0/npm 11.13.0 工具链完成：

```powershell
npm.cmd ci
npm.cmd test
npm.cmd run verify
npm.cmd run test:live
```

其中 `npm test` 是不依赖网站的离线回归，`npm run verify` 是交付门槛；`test:live` 是来源行为变更
后的线上 smoke，不能伪造通过或作为常规 CI 的唯一测试。Windows Debug 可以在构建 `dist/` 后直接
加载工作区进行电脑端 Runtime 直测，但它不能替代上述 Node 测试、线上 smoke 或 Android 正式
`.mgplugin` 安装验收。正文、HTML、URL、搜索词、用户输入和敏感值不得进入日志或测试产物。
