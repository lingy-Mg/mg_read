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

## 插件私有缓存

分类与搜索列表 HTML 缓存 10 分钟，作品详情和章节目录 HTML 缓存 1 小时；正文和任何下载内容
不落盘。每个条目最多 1 MiB，总量最多 100 MiB，按最近访问时间淘汰。过期条目会优先在线
刷新；只有刷新失败时才作为离线回退返回。HTTP 失败响应、超限内容、损坏条目均不缓存。

缓存仅写入 Runtime 注入的绝对 `ctx.cacheDir/html-cache-v1/`，其上层已经是
`plugin-cache/<plugin-id>/`。键为 URL 的 SHA-256 摘要，缓存文件不含原始 URL；插件绝不读取、
创建或删除 `ctx.cacheDir` 之外的文件。缓存读写、损坏与清理失败都会降级为缓存未命中，不能让
书源调用失败。主程序未来只能经 Runtime 的强类型接口统计或清理该目录，不能取得路径或文件句柄。

`npm run pack:plugin` 输出确定性 `.mgplugin` 到忽略的 `artifacts/`。安装后于下一次 Runtime
冷启动激活。插件不处理账号、登录、Cookie 导出、下载、绕过访问控制或 Runtime 内部通信。
