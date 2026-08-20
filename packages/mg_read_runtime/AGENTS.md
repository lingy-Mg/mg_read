# mg_read_runtime Agent 增量规则

monorepo 根 [AGENTS.md](../../AGENTS.md) 始终适用。本文件只补充 Runtime package 的所有权、
工具链和验证规则。

## 渐进式读取

- Facade/边界：读 [Runtime 契约](docs/standalone-runtime-contract.md)。
- desktop Supervisor、ready、Job Object、WS/HTTP：再读
  [desktop 证据](docs/desktop-runtime-bridge.md) 与根
  [Runtime 生命周期](../../docs/architecture/03-runtime-lifecycle.md)/
  [内部传输](../../docs/architecture/05-transport-protocol.md)中相关章节。
- Node/Javet/ABI/升级：读 [版本矩阵](docs/runtime-version-matrix.md) 和 [probes](probes/README.md)。
- package/lock/安装/冷激活：读根
  [标准插件专题](../../docs/architecture/04-plugin-sdk-packaging-registry.md) 与相关 ADR。
- Flutter Facade：读 [package README](packages/mgread_plugin_runtime/README.md)。
- 性能或诊断：读 [性能快照](docs/standard-plugin-performance-baseline.md)、根日志专题和受影响测试。

不要同时预加载这些文件。旧 `agent.md` 仅是兼容跳转，不是第二份规则。

## Runtime 所有权

- 本 package 拥有 Node Runtime Core、Android Javet Adapter、Windows/macOS Node launcher、
  Supervisor、内部 WS/HTTP、Plugin API、标准插件安装执行、Schema/fixture、诊断和唯一
  Flutter-facing Facade。
- 每个应用进程只有一个 Node Runtime/VM。禁止 Worker、子进程、第二 VM、Engine Pool、插件
  native addon 或自定义 ESM Loader/VM 隔离。
- 生产 Facade 不接受 main-app 数据库/路径、Cookie、文件服务、callback、HostPort、平台通道或
  raw transport 注入；不暴露 executable、PID、端口、ready、bootId、WS/HTTP URL 或 envelope。
- Runtime 自有数据根可以保存插件不可变版本、插件私有 data/cache、Cookie、临时资源、运行
  状态和 Runtime diagnostics。它不得保存主应用书架、目录、正文、阅读进度或书签的业务权威，
  也不得打开主应用 SQLite/文件对象。
- 下载 checkpoint、缓存和跨边界文件提交没有新 Accepted ADR/强类型契约前保持未实现或稳定
  `unsupported`；不得恢复旧 Runtime Store 全权方案，也不得临时增加 `host.*` 回调。

## 插件与平台规则

- 标准插件只使用 `package.json.mgread`、lockfile v3、普通多文件输出和普通 `node_modules`。
  不恢复 manifest、bundle、shared dependency、自定义 lock 或旧模板 RPC。
- Runtime 不执行 npm/pnpm/install scripts，不求解 SemVer；拒绝 Git dependency、包外 `file:`、
  native addon 和原生文件。依赖对象仓的 hardlink/copy 只是内部存储优化。
- 插件版本不可变，只在下次应用进程冷启动激活；当前进程不热替换或热重启 Runtime。
- Android 一个专用线程持有一个 Javet `NodeRuntime`；desktop 只从 package 固定路径启动精确
  Node。Windows Job Object、macOS 签名/公证和 Android ABI 都由本 package 验收。
- desktop 代理只允许显式 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` 与 Windows 手工 Internet
  Settings。PAC/WPAD 需要按目标 URL 的专用 resolver，不能展平成固定代理。

## 日志与插件调用

- Runtime diagnostics 只持久化有界分段 TXT。默认不读取/复制 body、HTML、JSON、正文、URL
  query、用户输入、凭据、Cookie、token、路径或 raw exception。
- 每个 control request 与 plugin invocation 有唯一 owner span、queue wait、执行时长和恰好一个
  终态。插件脚本使用 `ctx.log` 记录小型阶段事件，网络只走 `ctx.http`。
- capability 修改必须验证 Facade、control、plugin invocation、script 和 HTTP 的 trace 关联，
  覆盖 success 与适用的 timeout/cancel/error，并放置 secret/content canary。

## Windows 固定工具链

Windows 所有 Node/npm/Corepack/脚本必须使用：

```text
tools/node-v24.16.0-win-x64/node.exe
tools/node-v24.16.0-win-x64/npm.cmd
```

先把该目录放到 `PATH` 最前，禁止裸用全局 `node/npm/npx/corepack`，也禁止缺失时回退。固定
Node `24.16.0`、npm `11.13.0` 必须与 `.node-version`、package/lock、compatibility fixture 和
版本矩阵一致。

## 验证

实现变更使用项目内工具链运行：

```powershell
npm.cmd ci
npm.cmd run typecheck
npm.cmd test
npm.cmd run check:no-native-addons
```

- 触及 desktop Facade/transport：加 `npm.cmd run test:flutter-desktop`。
- 触及性能关键路径：按任务运行 benchmark 并报告 off/default/explicit capture 边界。
- 触及 Windows 打包：运行 `stage:flutter-windows`，但它不替代最终应用包验收。
- Android/Javet、Windows 发布包、macOS 签名/公证分别报告；当前主机未运行的项明确写未执行。
- Runtime-only 任务不修改根 UI、reader、模板或真实书源，除非用户明确把它们纳入同一交付包。
