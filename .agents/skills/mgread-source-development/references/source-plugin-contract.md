# 数据源项目与内容契约

## 事实入口

- 默认参考来源公开类型：`plugins/sources/aisishuwu/src/mgread-api.ts`
- Runtime 上下文与内容校验：`packages/mg_read_runtime/src/plugin-manager-contract.ts`、
  `plugin-content-types.ts`、`plugin-content-validation.ts`
- 项目与 artifact：`plugin-package.ts`、`plugin-single-file.ts`、`plugin-archive.ts`
- 真实数据源增量：`plugins/sources/AGENTS.md`、目标入口文件头和直接测试

不要从本参考推断当前字段或版本；以这些公开类型、package metadata 和测试为准。

## 项目与生命周期

- 数据源是 Node.js 24 ESM 项目，`package.json.mgread` 是唯一 MgRead 元数据。
- 模块导入阶段不得访问尚未注入的上下文；`activate(ctx)` 只保存公开上下文，不创建 Worker、子进程、
  native addon、第二 VM 或自定义 loader。
- Runtime 依次调用 `discover/search/getDetail/getChapters/getContent`；可选 capability 只有公开类型声明的集合。
- ID、cursor、target 和 chapterId 必须稳定、不透明、可回传。URL、标题、索引和页码不能替代稳定身份。
- 必填值必须存在；未知可空值显式为 `null`，零值不能当未知，集合始终为数组。

## 内容与资源

- 来源返回内容语义；Flutter 拥有组件、主题、断点、尺寸、导航和交互。
- 小说使用 `text`，漫画使用有序 `pages`，音视频使用 Runtime proxy 的 `media`。正文和媒体主体不进入
  日志、fixture、缓存或控制面。
- `ctx.resource.proxy` 只投影来源允许的请求；插件不向 Flutter 暴露 Cookie、签名头或上游临时 URL。
- 私有缓存只保存可重复 GET 的展示投影。发现/搜索、详情/目录分别使用项目已声明的策略；stale 可读、
  刷新单飞，失败按 miss。正文、媒体、登录数据和写响应不得缓存。
- capability 日志只写有界阶段和稳定错误码，不写 URL/query、搜索词、标题、HTML、正文、Cookie、token、
  凭据或原始异常。

## Artifact

- `single-file` 构建为 Node 24 ESM `.mgplugin.js`，内联实际使用的可打包依赖；不要求 archive 的依赖恢复。
- `archive` 构建为 `.mgplugin`，保留 lock 和本地 package 恢复语义。两种模式不互相回退。
- 产物不得包含源码或 `node_modules`；descriptor、图标、大小和 SHA-256 必须可复核。
- 构建库返回内存 bytes/fileName/format，只有 CLI 写入 artifact 目录。

## 最小验证

在目标数据源目录使用仓库固定 Node/npm，运行实际声明的 typecheck、离线测试和 `verify`。请求、选择器、
分页或解析变化才增加 `test:live`；live 只做网络 smoke，不保存响应。

构建声明的 artifact 模式，验证 descriptor、大小、SHA-256 和包内容；安装语义变化时再用临时 Runtime 数据根
执行冷安装与激活。Fixture 只保留触发结构和错误分支所需的最小脱敏内容。
