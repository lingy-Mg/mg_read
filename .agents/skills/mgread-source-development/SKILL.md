---
name: mgread-source-development
description: Develop, debug, or test MgRead real data-source plugins, the public Source API across Runtime and Flutter, source-owned discovery composition, or ctx.webview providers. Do not use for bookshelf/home/recent-reading state, long-press details, ordinary discovery UI, reader UI, or player-host work unless the public Source contract also changes.
---

# MgRead 数据源开发

处理真实数据源、公开 Source 契约、源拥有的发现组合和 `ctx.webview` 宿主。先按仓库 `AGENTS.md` 读取目标
文件头、最近规则、公开类型和直接测试；本技能只补充来源特有的非显然边界。

## 选择一个首选参考

- Node 项目结构、生命周期、缓存、资源代理或 artifact：读
  [source-plugin-contract.md](references/source-plugin-contract.md)，再从当前同类真实数据源读取最近
  `AGENTS.md`、`package.json`、公开类型、入口和直接测试；仓库不维护空白官方模板。
- 开发期轻量验证、单源/全源回归或正式 Windows App CLI 验收：读
  [source-testing-workflow.md](references/source-testing-workflow.md)。Node 阶段不得改用 `.ps1`/`pwsh` 包装；
  App CLI 阶段不得用 Flutter 测试代替正式可执行文件。
- 当前网页结构、选择器、JS DOM、跳转或分页取证：加载 `browser:control-in-app-browser` 并读
  [real-page-browser-probing.md](references/real-page-browser-probing.md)
- 公开发现组件类型、Runtime/Facade 解码或宿主渲染：
  [discovery-contract.md](references/discovery-contract.md)
- 真实来源的发现区块、小说/漫画/音频/视频组件选型、简单首页补全与响应式组合：
  [discovery-composition.md](references/discovery-composition.md)
- 数据源调用 `ctx.webview`：读 [webview-api.md](references/webview-api.md)，再核对 Runtime 当前公开类型、
  直接测试和一个真实 WebView 来源。
- Android/Windows browser provider、宿主状态机或原生输入：读
  [webview-host-development.md](references/webview-host-development.md)及对应平台实现和直接测试。
- 音频或视频来源：读 [media-source-contract.md](references/media-source-contract.md)，再选择一个同媒体类型来源。
- 漫画来源只选择 `baozimh-com` 或 `manhuagui-com` 中与目标最接近的一个。

只有公共边界确实跨域时才增加第二个参考；不要默认加载所有参考或无关平台实现。

## 不可违反的边界

- 数据源只依赖公开 `MgReadPluginContext`，不依赖 Runtime 端口、wire envelope、PID、原生 WebView 对象、
  主应用数据库或宿主路径。上下文和 WebView 类型的唯一声明包是
  `packages/mg_read_source_api`，数据源必须从 `@mgread/source-api` 使用 `import type` 引用；禁止在来源
  内复制 `MgReadPluginContext`、`PluginWebViewPage`、`PluginWebViewApi` 或其字段子集。修改公共接口时先同步
  该包，再同步 Runtime 实现、直接测试和本技能参考。
- 来源拥有真实数据和稳定不透明 ID/target/cursor；Runtime 校验，Flutter 拥有组件实现、主题、尺寸、导航
  和交互。不得伪造来源缺失字段、热门词或线上证据。
- 每个数据源只有一个宿主持有的 WebView 页面；Cookie、UA、Profile 和输入由宿主持有。禁止 Cookie API、
  token 抽取/回放、DOM 合成点击和绕过。`page.cdp` 只能通过共享声明调用；当前 Windows WebView2 支持、
  Android 返回 `unsupported`，不得用它绕过挑战。需要人工操作时返回 `interaction_required`。
- `single-file` 与 `archive` 是独立发布模式，不互相回退，也不能把 `.mgplugin` 当成 `.mgplugin.js`。
- 音频与视频分别建模；媒体主体、HLS 分片和 Range 只经 Runtime 数据面流转，插件 JS 返回资源描述。

## 完成与报告

公开 Source 边界变化按受影响范围同步 Runtime 类型/校验、Facade/解码、宿主、受影响参考来源、直接测试和
唯一相关核心章节。交付时分开报告静态检查、自动化、fixture/live、artifact/冷安装、Windows、Android、
真实运行和未执行项；任何一层都不能替代另一层。

数据源开发循环使用纯 Node 单源检查；开发完成后必须再用 Windows 正式 App CLI 对目标来源执行完整链路。
测试库、Runtime 公共边界或跨来源共用逻辑变化时，两阶段都追加全源模式。不得因 Node 通过而省略 App CLI，
也不得用 App 的一次线上通过替代来源自身的离线测试和契约检查。
