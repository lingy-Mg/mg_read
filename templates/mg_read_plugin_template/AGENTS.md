# 官方空白插件模板增量规则

状态：开发规范。根契约适用。本目录只维护可复制的空白 Node 插件项目；按任务读取标准插件专题中
的 package、artifact、内容字段或缓存标题，不预加载 Runtime/主应用内部文档。

## 模板边界

- `package.json.mgread` 是唯一 MgRead 元数据，lockfile v3 是开发依赖图。开发输出为普通多文件
  ESM；发布默认生成核心规范定义的确定性 `.mgplugin.js`，显式 archive 才生成兼容 `.mgplugin` ZIP。
- artifact 不包含 `node_modules` 或源码。禁止 manifest、shared/bundled dependency、自定义 lock、
  Git dependency、install-time native build、native addon、自定义 VM/loader 或包外 `file:`。
- 保持六个必需 Plugin API v1 export；可选热门词使用 `searchSuggestions`。固定 nullable 键显式为
  `null`，集合始终为数组。
- 模板不得加入真实来源、账号、凭据、反爬绕过或网络目标；测试必须确定性、本地且离线。

## 日志、缓存与验证

- production capability 只用公开 `ctx.log`，不记录 URL/query、用户输入、HTML/正文、Cookie、token、
  凭据或原始异常；测试覆盖成功和适用失败终态、secret/content canary 与日志失败隔离。
- 只缓存可重复远程 GET 的展示投影：发现/搜索 10 分钟，详情/目录 1 小时；使用 `ctx.cacheDir` 下
  的版本目录、哈希键、原子写、single-flight、每项 1 MiB/每插件 100 MiB LRU 和刷新失败后的 stale
  回退。禁止缓存正文/媒体、登录数据、写响应或主应用业务数据。
- 使用固定 Node/npm 工具链运行 `npm.cmd ci`、`npm.cmd test`、`npm.cmd run verify` 和
  `npm.cmd run pack:plugin`。模板不为满足 smoke 人为增加线上目标；Windows Debug 直载不能替代
  Node 门禁或 Android packaged-plugin 验收。
