# 爱丽丝书屋 MgRead 书源

这是一个位于 monorepo 专用 `plugins/sources/` 目录的标准 Node.js 24 MgRead
书源。它按公开的 Plugin API v1 实现首页重磅推荐幻灯片、分类、排行、搜索、详情、目录和正文；网站 HTML、URL
解析规则及请求头只在本插件内，不穿透到 Flutter 主应用或 Runtime transport。

## 运行方式

```powershell
$env:PATH = "$PWD\..\..\..\packages\mg_read_runtime\tools\node-v24.16.0-win-x64;$env:PATH"
npm.cmd ci
npm.cmd test
npm.cmd run verify
npm.cmd run test:live
```

`npm test` 是不依赖网站的离线回归，`npm run verify` 是交付前门槛。修改来源解析或请求规则后，
必须再执行 `npm run test:live`；线上 smoke 失败时不能把该来源标记为已完成。Windows Debug 可以
直接读取构建后的工作区 `dist/`，下一次书源调用会触发 development Runtime 按指纹重载，不需要先
打包或安装；这不替代 Android 的正式插件 artifact 验收。

`npm run test:live` 是明确的线上 smoke 测试：它实际请求目标站点的分类、搜索、详情、目录
和正文页面，但不保存返回 HTML 或正文。它依赖站点可用性，不应作为常规离线 CI 的唯一测试。

## 插件私有缓存

首页重磅推荐、发现分类和排行列表的 HTML 在一小时内直接命中；超过一小时仍先显示旧的书名/封面投影，并只发起一次后台
刷新，让下一次进入使用新数据。搜索维持 10 分钟刷新窗。详情与章节目录则严格要求一小时内：过期时
必须刷新成功，不能用旧详情静默回退。搜索建议使用首页“热门推荐小说”缓存 24 小时；正文和任何下载内容不落盘。
发现阶段已解析的详情会复用于随后打开详情和入书架，目录聚合也会在有效期内复用，避免重复网络与解析。

缓存实现来自本地 `@mgread/plugin-cache` 包，不发布 npm。它同时保存 HTML 与经过校验的详情/目录
投影：列表为获取封面补详情时，即使投影过期也优先返回旧投影并单飞后台刷新；用户主动打开详情或目录
仍要求一小时内的新数据。`npm run build` 会从仓库的 `packages/mg_read_plugin_cache/` 同步其开发
副本；默认 single-file 发布把实际引用的纯 JavaScript 合并进 bundle，Runtime 安装时无需恢复
`node_modules` 或联网。
每个条目最多 1 MiB，总量最多 100 MiB，按最近访问时间淘汰。HTTP 失败响应、超限内容、损坏条目均不缓存。

缓存仅写入 Runtime 注入的绝对 `ctx.cacheDir/plugin-cache-v2/`，其上层已经是
`plugin-cache/<plugin-id>/`。HTML 使用 URL、详情/目录投影使用不透明内容 ID 的 SHA-256 摘要；缓存
文件不含原始 URL 或书籍身份值。插件绝不读取、创建或删除 `ctx.cacheDir` 之外的文件。缓存读写、
损坏与清理失败都会降级为缓存未命中，不能让
书源调用失败。主程序未来只能经 Runtime 的强类型接口统计或清理该目录，不能取得路径或文件句柄。

`npm run pack:plugin` 输出确定性
`artifacts/org.mgread.aisishuwu-0.2.8.mgplugin.js`。它内联纯 JavaScript 依赖，并在规范信封内携带
`assets/icon.png` 的字节、大小和 SHA-256；不携带 lock、源码、`node_modules` 或 sidecar。安装后
于下一次 Runtime 冷启动激活。插件不处理账号、登录、Cookie 导出、下载、绕过访问控制或 Runtime
内部通信。
