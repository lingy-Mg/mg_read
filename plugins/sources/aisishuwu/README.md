# 爱丽丝书屋 MgRead 书源

这是一个位于 monorepo 专用 `plugins/sources/` 目录的标准 Node.js 24 MgRead
书源。它按公开的 Plugin API v1 实现分类、搜索、详情、目录和正文；网站 HTML、URL
解析规则及请求头只在本插件内，不穿透到 Flutter 主应用或 Runtime transport。

## 运行方式

```powershell
$env:PATH = "$PWD\..\..\..\packages\mg_read_runtime\tools\node-v24.16.0-win-x64;$env:PATH"
npm.cmd ci
npm.cmd run verify
npm.cmd run test:live
```

`npm run test:live` 是明确的线上 smoke 测试：它实际请求目标站点的分类、搜索、详情、目录
和正文页面，但不保存返回 HTML 或正文。它依赖站点可用性，不应作为常规离线 CI 的唯一测试。

`npm run pack:plugin` 输出确定性 `.mgplugin` 到忽略的 `artifacts/`。安装后于下一次 Runtime
冷启动激活。插件不处理账号、登录、Cookie 导出、下载、绕过访问控制或 Runtime 内部通信。
