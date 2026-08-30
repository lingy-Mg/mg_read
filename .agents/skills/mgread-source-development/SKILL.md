---
name: mgread-source-development
description: Develop or debug MgRead real data-source plugins, the public Source API across Runtime and Flutter, source-owned discovery composition, or ctx.webview providers. Do not use for bookshelf/home/recent-reading state, long-press details, ordinary discovery UI, reader UI, or player-host work unless the public Source contract also changes.
---

# MgRead 数据源开发

处理真实数据源、公开 Source 契约、源拥有的发现组合和 `ctx.webview` 宿主。先按仓库 `AGENTS.md` 读取目标
文件头、最近规则、公开类型和直接测试；本技能只补充来源特有的非显然边界。

## 选择一个首选参考

- Node 项目结构、生命周期、缓存、资源代理或 artifact：默认读取 `plugins/sources/aisishuwu/` 的最近
  `AGENTS.md`、`package.json`、公开类型、直接测试和 `tools/mgread.mjs`。漫画、WebView、音频或视频任务
  改读当前同类真实数据源；仓库不维护空白官方模板。
- 当前网页结构、选择器、JS DOM、跳转或分页取证：加载 `browser:control-in-app-browser` 并读
  [real-page-browser-probing.md](references/real-page-browser-probing.md)
- 公开发现组件类型、Runtime/Facade 解码或宿主渲染：
  [discovery-contract.md](references/discovery-contract.md)
- 真实来源的发现区块选择与响应式组合：
  [discovery-composition.md](references/discovery-composition.md)
- 数据源调用 `ctx.webview`：参考 `diyibanzhu-me` 或 `xiezhenji`，并核对 Runtime 当前公开类型和直接测试。
- Android/Windows browser provider、宿主状态机或原生输入：读取对应平台实现、最近 `AGENTS.md` 和直接测试。
- 漫画参考 `baozimh-com` 或 `manhuagui-com`；音频参考 `tingchina-audio`；视频参考 `hsck-video`。

只有公共边界确实跨域时才增加第二个参考；不要默认加载所有参考或无关平台实现。

## 不可违反的边界

- 数据源只依赖公开 `MgReadPluginContext`，不依赖 Runtime 端口、wire envelope、PID、原生 WebView 对象、
  主应用数据库或宿主路径。
- 来源拥有真实数据和稳定不透明 ID/target/cursor；Runtime 校验，Flutter 拥有组件实现、主题、尺寸、导航
  和交互。不得伪造来源缺失字段、热门词或线上证据。
- 每个数据源只有一个宿主持有的 WebView 页面；Cookie、UA、Profile 和输入由宿主持有。禁止 Cookie API、
  token 抽取/回放、CDP、DOM 合成点击和绕过；需要人工操作时返回 `interaction_required`。
- `single-file` 与 `archive` 是独立发布模式，不互相回退，也不能把 `.mgplugin` 当成 `.mgplugin.js`。
- 音频与视频分别建模；媒体主体、HLS 分片和 Range 只经 Runtime 数据面流转，不在插件 JS 中整体读取、
  Base64 化、缓存或持久化签名 URL。

## 完成与报告

公开 Source 边界变化按受影响范围同步 Runtime 类型/校验、Facade/解码、宿主、受影响参考来源、直接测试和
唯一相关核心章节。交付时分开报告静态检查、自动化、fixture/live、artifact/冷安装、Windows、Android、
真实运行和未执行项；任何一层都不能替代另一层。
