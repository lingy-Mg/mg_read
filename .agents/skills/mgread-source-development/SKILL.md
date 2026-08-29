---
name: mgread-source-development
description: Develop, review, package, or debug MgRead data-source plugins and source-owned discovery composition across Runtime, Flutter Facade/UI, the official template, real sources, ctx.webview, Android WebView, Windows WebView2, and source verification. Use for data-source or cross-layer source capability work; do not use for unrelated reader or library UI.
---

# MgRead 数据源开发

统一处理真实数据源、发现组合、官方模板和数据源专用 Runtime/平台能力。技能记录的是决策约束和检查入口；当前公开类型、测试及目标文件头仍是实现事实。

## 安全起点

1. 从包含本技能的仓库根目录工作。读取根 `AGENTS.md`，检查分支、`git status --short` 和任务相关 diff，保留无关并发修改。
2. 读取目标文件头、最近的嵌套 `AGENTS.md`、直接测试与公开类型；通过 `docs/development/README.md` 只定位需要的 `docs/core.md` 章节。
3. 先判断任务模式，再完整读取对应参考。不要为了了解项目一次加载全部参考、全部文档或全部平台实现。
4. 技能中的版本、路径、来源编排和已知缺口必须用当前代码复核；发现漂移时同步修正对应参考。

## 按任务路由

- 数据源函数、生命周期、缓存、资源代理、项目结构或 artifact：读取 [references/source-plugin-contract.md](references/source-plugin-contract.md)。
- 递归发现组件、布局枚举、nullable 字段、语义图标、Runtime/Facade 解码或宿主渲染：读取 [references/discovery-contract.md](references/discovery-contract.md)。
- 选择发现组件、响应式组合，或修改爱丽丝/速读谷等真实来源编排：读取 [references/discovery-composition.md](references/discovery-composition.md)；只有公开形状变化时再加载发现契约。
- 数据源调用 `ctx.webview`，或修改其公开类型和行为：读取 [references/webview-api.md](references/webview-api.md)。
- 修改 browser provider、Android WebView、Windows WebView2、窗口控制、错误传播、输入或安全边界：读取 [references/webview-host-development.md](references/webview-host-development.md)。
- 准备测试、打包、版本更新、真机验证或交付结论：读取 [references/verification.md](references/verification.md)，只执行受影响边界对应的矩阵。

常见组合：局部解析修复读取“插件契约 + 验证”；纯发现编排读取“发现组合 + 验证”；发现公开契约变化读取“两份发现参考 + 验证”；跨平台 WebView 变化读取“两份 WebView 参考 + 验证”。

## 共享产品边界

- 数据源是标准 Node.js 24 插件，只依赖公开 `MgReadPluginContext`。不得依赖 Runtime 端口、WS/HTTP envelope、PID、原生 WebView 对象或宿主路径。
- 来源拥有真实数据、稳定不透明 ID/target/cursor 和内容语义；Runtime 校验边界，Flutter 宿主拥有组件实现、主题、尺寸、断点、可访问性、导航和交互。
- 插件只能返回允许列表中的语义组件、布局和图标名；不得返回 Flutter 代码、`IconData`、字体码点、任意样式、颜色或来源控制的列数。
- 必填值、显式 `null`、零值和空数组语义不能混用。不得伪造来源缺失的数据、热门词或线上验证证据。
- `ctx.webview` 每个数据源强制一页，无 `sessionKey`、`onUrlChanged` 或 Cookie API。Cookie、UA、Profile、窗口和输入设备由宿主持有。
- 禁止数据源抽取或回放挑战 token，禁止 CDP、DOM 合成点击、DOM value setter、全局输入或设备控制；Windows 仅允许用户主动按 F12 打开 DevTools。
- `single-file` 与 `archive` 是两个独立发布模式，不能互相降级，也不能把 `.mgplugin` archive 当成 `.mgplugin.js`。

## 跨层完成条件

公开边界变化必须按受影响范围交付完整链路：Runtime 类型与校验、公开导出、Flutter Facade/解码、宿主行为或渲染、官方模板、真实来源、直接测试，以及 `docs/core.md` 的唯一相关章节。不要因局部任务机械修改未受影响的平台。

交付时先给结果，再分开报告静态检查、自动化测试、来源 fixture/live、artifact/冷安装、Windows、Android、真实运行和未执行项。Mock、golden、Windows 与 Android 证据不能互相替代。
