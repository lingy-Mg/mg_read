---
name: mgread-source-development
description: Develop, migrate, repair, retire, audit, or batch-test MgRead real data-source plugins, or evolve their public Source API, discovery, resource, and WebView contracts. Do not use for bookshelf, reader, player UI, or generic plugin management unless a public Source boundary also changes.
---

# MgRead 数据源开发

处理真实来源及其公开 Source 边界。先按仓库 `AGENTS.md` 定位目标文件、最近规则、公开类型和直接测试；
本技能只补充来源特有且会改变决策的约束。

## 先选择一个主场景

| 当前任务 | 只读这个主参考 |
| --- | --- |
| 新建或修改单个来源、项目结构、缓存、资源代理、artifact、开发加载 | [source-plugin-contract.md](references/source-plugin-contract.md) |
| 修复失效来源、搜索/分页/解析或资源链路 | [source-repair-workflow.md](references/source-repair-workflow.md) |
| 批量健康检查、同类来源整顿、全源回归、简介审计 | [source-batch-audit.md](references/source-batch-audit.md) |
| 从旧格式或第三方仓库迁移来源 | [source-migration-workflow.md](references/source-migration-workflow.md) |
| 删除、退役或停止发布来源 | [source-retirement-workflow.md](references/source-retirement-workflow.md) |
| 只设计或执行自动化、Node/App CLI 验收 | [source-testing-workflow.md](references/source-testing-workflow.md) |
| 修改通用 Source API、资源契约、安装/开发加载或 Runtime 来源生命周期 | [source-plugin-contract.md](references/source-plugin-contract.md) |
| 修改发现公开类型、Runtime/Facade 解码或 Flutter 宿主渲染 | [discovery-contract.md](references/discovery-contract.md) |
| 修改 `ctx.webview` 公开 API | [webview-api.md](references/webview-api.md) |
| 修改 Windows/Android WebView provider 或平台状态机 | [webview-host-development.md](references/webview-host-development.md) |

## 只在命中条件时增加一个参考

- 需要确认当前网页路由、DOM、选择器、脚本渲染或验证页：
  [real-page-browser-probing.md](references/real-page-browser-probing.md)
- 需要验证封面、小说正文、漫画页图、音频、视频或 HLS：
  [content-validation-matrix.md](references/content-validation-matrix.md)
- 只调整来源首页区块、组件或封面方向：
  [discovery-composition.md](references/discovery-composition.md)
- 实现音频/视频目录、分组、播放资源或刷新语义：
  [media-source-contract.md](references/media-source-contract.md)

只有公开边界真实跨域时才继续增加参考。找到所有者、契约和验证入口后停止扩读，不默认加载全部参考、
同类来源或平台实现。

## 共同边界

- 来源只依赖 `@mgread/source-api` 的公开 `MgReadPluginContext`；不得复制 Context/WebView 类型，也不得依赖
  Runtime 私有端口、wire、PID、主应用数据库、宿主路径或原生对象。
- 来源拥有真实数据和稳定不透明的 `id/target/cursor/chapterId`；Runtime 负责校验，Flutter 负责组件实现、
  主题、尺寸、导航和交互。不得伪造缺失字段、热门词、简介或线上证据。
- 封面、漫画页图和音视频只登记经来源校验的资源描述；媒体主体、HLS、Range 和取消由 Runtime 数据面处理，
  插件不得整体缓冲或导出字节。
- 浏览器会话不得让来源读取、记录、导出或手写 Cookie、验证令牌和伪造 UA；需要同 Profile HTTP 时使用
  当前公开 session API，页面必须执行脚本时才保留最小 WebView 操作。
- Node 命令使用仓库固定 Node/npm。离线、live、Node CLI、artifact、Windows App CLI 和平台实机是不同证据，
  任何一层都不能替代另一层。

## 收尾

按主参考定义的范围运行直接测试；公开契约、testkit 或跨来源共用逻辑变化时扩大到受影响来源和全源模式。
交付时分开报告静态/离线、live、资源类型、artifact、Node CLI、Windows App CLI、Android/Windows 实机、
外部阻塞和未执行项。只提交本次拥有的明确文件。
