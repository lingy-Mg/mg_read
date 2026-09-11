# 旧来源迁移

## 先做可行性审计

用于把旧插件格式、远程仓库来源或旧脚本迁移到原生 Source API。先建立每来源审计表：原始标识、当前可达性、
内容类型、依赖能力、迁移状态和原因。分类至少包括：已存在、可用 `ctx.http`、可用公开 WebView、需要新增公共
契约、上游不可达、依赖不受支持、重复或明确放弃。

优先最大化可负责迁移的覆盖率，但每个跳过项必须有具体原因。暂时不可达不能自动等同于永远不兼容；需要
凭据、跨来源调用、旧 Runtime 私有 API、浏览器网络拦截、未支持转换或直接媒体缓冲的来源，在公共契约未支持前
不得用来源内旁路迁移。

## 转换边界

- 新项目遵守 [source-plugin-contract.md](source-plugin-contract.md)，只使用 `@mgread/source-api` 和公开
  `ctx.http`、`ctx.webview`、`ctx.resource.proxy`、日志/错误能力。
- 保留来源稳定身份与可回传 ID 语义，不把旧框架的内部对象、执行器或宿主状态带入新插件。
- 选择一个相同 `contentKind`、传输方式和 artifact 模式的真实来源作参考；不要复制一个全能模板。
- 若旧源依赖公开契约缺口，先把缺口作为独立跨层任务评估；迁移授权不等于授权扩大 Runtime/Flutter 协议。
- 审计记录是历史事实，不是活动插件注册表；迁移完成或来源退役时分别维护各自所有者。

## 验证与报告

每个迁移来源至少通过固定 Node 的 typecheck、离线契约/fixture、确定性 artifact 和适用 live 链路。按
[content-validation-matrix.md](content-validation-matrix.md)验证实际内容：小说正文、漫画页图、音频、视频/HLS
不能互相替代。再按 [source-testing-workflow.md](source-testing-workflow.md)执行 Node 单源；Windows 环境可用时
执行正式 App CLI。

报告总数必须满足 `已存在 + 已迁移 + 跳过 = 审计总数`，并列出每个跳过原因、当前原生覆盖总数、实际执行的
网络/平台证据和未执行项。系统 Node 或本机代理差异属于环境诊断，不得编码进来源实现。
