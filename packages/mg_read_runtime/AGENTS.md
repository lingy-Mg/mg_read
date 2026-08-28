# mg_read_runtime 增量规则

状态：开发规范。根 `AGENTS.md` 始终适用；本文件只补充 Runtime package 的所有权、固定工具链和
验证入口，不重复根级 Git、隐私、平台验收或数据权威规则。

## 按任务读取

- Facade/边界：读 Runtime 契约的“主项目唯一公开面”和“不变量”。
- desktop Supervisor、ready、Job Object、WS/HTTP：只读根生命周期/传输专题中的对应标题。
- Android Javet、Node/ABI 升级：只读版本矩阵的目标平台和对应 probe。
- package/lock/artifact：只读标准插件专题的“标准项目结构”“发布 artifact”；安装/回滚再加
  “installed 冷安装、激活与回滚”。
- Flutter Facade：读 `packages/mgread_plugin_runtime/README.md` 对应 API；日志任务读根诊断接入规范的
  Runtime 章节。

不要同时预加载上述材料。旧 `agent.md` 仅为兼容跳转。

## Package 所有权

- 本 package 独立拥有 Node Runtime Core、Android Javet Adapter、Windows/macOS Node launcher、
  Supervisor、内部 WS/HTTP、Plugin API、安装执行、schema/fixture、瞬时诊断和唯一 Flutter Facade。
- 生产 Facade 不接受主应用数据库/路径、Cookie、文件服务、callback、HostPort、平台通道或 raw
  transport 注入，也不暴露 executable、PID、端口、ready、bootId、WS/HTTP URL 或 envelope。
- Runtime 自有数据根只保存插件不可变版本、插件私有 data/cache、Cookie、临时资源和运行状态。
  下载 checkpoint 或跨边界文件提交在没有核心规范和强类型契约时保持未实现或 `unsupported`。
- installed 插件只在冷启动激活。Windows Debug development 指纹变化后先回收旧 VM，再启动唯一
  Runtime；不在同一 VM 热替换。Android 由一个专用线程持有一个 Javet `NodeRuntime`。
- desktop 只接受显式 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` 与 Windows 手工 Internet Settings；
  PAC/WPAD 需要按目标 URL 的专用 resolver，不能展平成固定代理。
- `browser.session.v1` provider 是唯一浏览器反向能力：插件仅传有界同源请求或 WebView 会话内的
  坐标/原生输入/控件点击操作，平台持有 Cookie、UA、验证 UI 与会话缓存；新增平台实现必须覆盖
  取消/超时/交互需求和跨插件隔离，不能退回 raw callback 或桌面全局输入。
- Android 浏览器 provider 每个 `pluginId` 最多一个 WebView；支持 multi-profile 时使用独立 Profile，最多 8 个驻留
  会话和 16 个待处理请求。`webview` 注入只能使用宿主固定脚本，`http` 只能在宿主内部读取 Profile Cookie/UA；
  `visible` 使用全局唯一可隐藏弹窗，`hidden` 不附着 View。multi-profile 不可用时必须明确记录
  `single_fallback` 降级日志，并使用应用默认单体 WebView Profile；该模式不提供跨插件 Cookie 隔离。
- Windows provider 通过现有内部 WebSocket 的 server-direction `host.browserSession.v1` 反向帧到达 Flutter
  package，再进入固定版本 WebView2 原生插件；不得新增公开 HostPort、凭据参数或 raw script API。每个
  `pluginId` 使用独立 UDF 和至多一个 WebView2；`visible` 全局只显示一个可隐藏窗口，`hidden` 从不显示。
  数据源 WebView 交互只允许宿主固定脚本查询 `getBoundingClientRect()`；点击和原生输入必须从该 WebView
  宿主输入入口投递，不使用 `HTMLElement.click()`、DOM `dispatchEvent()`、DOM value setter 或 CDP。

- WebView2 SDK 固定为 `Microsoft.Web.WebView2 1.0.4129.50` 并静态链接 Loader；运行设备仍须安装
  Evergreen WebView2 Runtime。SDK 下载 URL 与 SHA-256 同时固定，升级时核对官方 NuGet、许可证、
  下载大小并重新执行 Windows Debug 构建。

## 固定工具链与验证

Windows 必须把 `tools/node-v24.16.0-win-x64` 放到 `PATH` 最前并使用其中的 Node 24.16.0/npm
11.13.0；禁止裸用或回退全局工具。实现变更运行：

```powershell
npm.cmd ci
npm.cmd run typecheck
npm.cmd test
npm.cmd run check:no-native-addons
```

- desktop Facade/transport 加 `npm.cmd run test:flutter-desktop`；性能路径运行对应 benchmark；Windows
  打包加 `stage:flutter-windows`。
- Android/Javet、Windows 发布包、macOS 签名/公证分别报告，不能相互替代。
- WebView 变更至少运行 `:mgread_plugin_runtime:compileDebugKotlin`、相邻 Kotlin 单测和 Node
  `browser-session` contract；真实 CF 与弹窗交互只由允许的 Android integration_test 关闭。
- Windows WebView2 变更先跑 Node reverse-broker、Dart fake-platform/HTTP、Facade reverse-wire fixture，
  再跑 `flutter build windows --debug`。mock 只证明契约；只有真实 Windows WebView2 弹窗和目标站请求
  才能证明桌面浏览器层，且不能替代 Android 设备证据。
- Runtime-only 任务不修改根 UI、reader、模板或真实书源，除非用户明确纳入同一交付包。
