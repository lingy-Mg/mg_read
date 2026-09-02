# 数据源项目与内容契约

## 事实入口

- 数据源唯一宿主上下文声明：`packages/mg_read_source_api/index.d.ts`
- 数据源引用示例：`packages/mg_read_source_api/README.md`
- Runtime 上下文与内容校验：`packages/mg_read_runtime/src/plugin-manager-contract.ts`、
  `plugin-content-types.ts`、`plugin-content-validation.ts`
- 项目与 artifact：`plugin-package.ts`、`plugin-single-file.ts`、`plugin-archive.ts`
- 真实数据源增量：`plugins/sources/AGENTS.md`、目标入口文件头和直接测试

不要从本参考推断当前字段或版本；以共享公开类型、package metadata 和测试为准。来源内容结果类型可以
按媒介在来源内声明，但宿主上下文不得复制。

## 项目与生命周期

- 数据源是 Node.js 24 ESM 项目，`package.json.mgread` 是唯一 MgRead 元数据。
- 模块导入阶段不得访问尚未注入的上下文；`activate(ctx)` 只保存公开上下文，不创建 Worker、子进程、
  native addon、第二 VM 或自定义 loader。
- Runtime 依次调用 `discover/search/getDetail/getChapters/getContent`；可选 capability 只有公开类型声明的集合。
- ID、cursor、target 和 chapterId 必须稳定、不透明、可回传。URL、标题、索引和页码不能替代稳定身份。
- 必填值必须存在；未知可空值显式为 `null`，零值不能当未知，集合始终为数组。

## 内容与资源

- 来源返回内容语义；Flutter 拥有组件、主题、断点、尺寸、导航和交互。
- 小说使用 `text`，漫画使用有序 `pages`，封面与音视频使用 Runtime proxy。
- `ctx.resource.proxy` 只登记数据源已校验的 `kind + url + headers` 请求；Runtime 以明文可逆 Base64URL
  JSON 把完整描述放进 loopback URL，不依赖进程内 token 映射；此编码不提供加密或认证。Runtime 持有上游
  fetch、取消与流式响应。数据源不得导出 `resource` 字节能力或调用 `arrayBuffer()` 缓冲媒体。
- 私有缓存使用发现/搜索、详情/目录分别声明的项目策略；stale 可读、刷新单飞，失败按 miss。
- capability 日志记录来源运行阶段和结果。

## Artifact

- `single-file` 构建为 Node 24 ESM `.mgplugin.js`，内联实际使用的可打包依赖；不要求 archive 的依赖恢复。
- `archive` 构建为 `.mgplugin`，保留 lock 和本地 package 恢复语义。两种模式不互相回退。
- 产物不得包含源码或 `node_modules`；descriptor、图标、大小和 SHA-256 必须可复核。
- 构建库返回内存 bytes/fileName/format，只有 CLI 写入 artifact 目录。

## Windows 桌面开发生命周期

- Windows Debug/Release Node Runtime 都会监听用户选择的开发根下的项目变更；每个项目静默 1.5 秒后，通过随发布包携带的固定 Node/npm 执行该项目
  声明的 `npm run build`，不直接加载 TypeScript、不启动 `tsc -w`、不自动安装依赖。
- 开发构建成功后，Runtime 从唯一私有 generation 路径加载新的 `dist` 并完成候选激活；只有激活成功才
  替换当前 generation。构建或激活失败保留旧版本。
- 此处的构建不是 artifact 打包，不生成 `.mgplugin`/`.mgplugin.js`，也不进入安装流程。Flutter 只消费
  路径无关的变更事件并刷新来源快照；Android 不接入目录监听或构建链路。

## 最小验证

在目标数据源目录使用仓库固定 Node/npm，运行实际声明的 typecheck、离线测试和 `verify`。请求、选择器、
分页或解析变化才增加 `test:live`；live 只做网络 smoke。

构建声明的 artifact 模式，验证 descriptor、大小、SHA-256 和包内容；安装语义变化时再用临时 Runtime 数据根
执行冷安装与激活。Fixture 由来源测试自行定义。
