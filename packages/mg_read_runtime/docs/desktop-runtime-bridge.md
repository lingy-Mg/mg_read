# Desktop Runtime 与标准 Node 插件闭环

## 状态与边界

本仓库当前在 Windows x64 源码环境实现并自动化验证一条完整的最小链路：Runtime-owned
Flutter Facade 启动固定 Node、完成 loopback ready/HTTP/WS 门禁，Core 从 Runtime-owned
data root 冷启动标准 Node 插件，再把插件列表与完整内容能力强类型投影给 Flutter。

```text
PluginRuntime.invoke(InstalledPluginsInvocation / Source*Invocation)
  -> Desktop Supervisor + Windows Job Object
  -> exact Node 24.16.0 child
  -> ready + /health/ready + runtime.hello
  -> PluginManager.initialize(runtimeDataRoot)
  -> package.json + package-lock.json + ordinary node_modules
  -> named activate/discover/search/getDetail/getChapters/getContent exports
  -> typed Flutter result
```

主项目没有 Node 路径、data root、端口、bootId、WS/HTTP handler 或 raw DTO。生产 data root
由 Facade 在 `%LOCALAPPDATA%/MgRead/runtime` 下拥有；仅 Runtime package 的 testkit 可使用临时
data root。

这不是全平台完成声明。Android/Javet、macOS bundle/signing、最终 Windows 应用包、完整
Runtime Store、大资源 HTTP、官方 registry 下载和正文缓存/下载尚未完成对应验收。

## 标准插件启动

CLI 要求 Runtime-owned `--data-root`，Core 在发送 ready 前：

1. 扫描 `plugins/<id>/versions/` 与 current/pending/disabled/uninstall 指针；
2. `pending` 存在时只在冷启动尝试加载；成功原子切换 current，失败记录 failed 并回退旧
   current；
3. 通过 `package.json.mgread` 与 lockfile v3 再校验当前版本；
4. 使用 Node 标准动态 import、模块解析和共享模块缓存加载入口，不创建 VM/Loader；
5. 调用命名 `activate(ctx)`，随后把插件加入可分派集合；
6. 完成全部扫描后才绑定业务 ready 投影。

Windows Debug 不携带 `default-plugins/`。平台适配器直接定位仓库 `plugins/sources`，Runtime
从工作区加载已经构建的标准项目；package/lock 或 `dist/assets/packages` 变化时，在下一次
Facade 调用前先回收旧进程/VM，再创建唯一的新 Runtime。Release 不解析工作区。

Android Integration Test 使用另一条路线：Windows 固定工具链先验证并打 `.mgplugin`，测试脚本
经 ADB 把归档放进 Debug 应用私有 inbox，Android Runtime 在 manager 冷初始化前调用正式
installer。它不扫描 Windows 目录，也不把 inbox 暴露给主应用。

`ctx` 当前包含 Runtime-owned `dataDir`、`cacheDir`、传播 signal/deadline 的 `http.fetch`、
只在 Debug listener 启用时进入有界内存尾部的简单 `log`、只读 `app` 和 `plugin`。插件安装树
视为只读，日志关闭即清空且不写盘。

## 内部控制面

默认方法：

- `runtime.hello`：版本和控制面上限协商；
- `runtime.ping`：轻量健康投影；
- `plugins.list.v1`：当前插件状态列表；
- `plugins.setEnabled.v1`：持久化启用状态，并在当前进程立即门禁内容调用；
- `source.discover.v1`：插件定义受限递归组件 document，或对指定内容集合的 append；
- `source.search.v1`：稳定 plugin ID、受限 query、分页和富内容摘要；
- `source.getDetail.v1`：富内容详情、别名和目录 URL；
- `source.getChapters.v1`：最多 5000 章、2 MiB 的单次完整强类型目录；
- `source.getContent.v1`：有界小说文本或漫画页资源元数据；
- `runtime.shutdown`：有幂等键的受控关闭。

控制面只绑定 `127.0.0.1:0`，验证协议/bootId/request ID/trace/deadline/对象参数，限制 4 MiB
frame、256 个在途请求和 8 MiB 写队列，并实现 RFC 6455 的 64 位 payload length。Facade deadline
后发 best-effort cancel，迟到响应不会完成其他调用。除 2 MiB 完整目录外的大内容必须走资源
HTTP capability，不能进入 JSON/Base64。

Windows Supervisor 在启动 child 前创建并持有
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` Job Object。正常关闭、Flutter owner 退出或异常释放 Job
时，内核清理已加入的 Node 及其后代；生产 Core 本身不需要向主项目暴露进程控制。

源码目录操作也遵守该所有权边界：`plugins.openCodeDirectory.v1` 只由 Node Core 解析并返回给
Runtime package 内部的 Flutter Supervisor，绝对路径不进入主应用 Facade。Explorer 由 Flutter
owner 在 Job Object 外启动，避免被 Node child 的进程树清理；失败只投影为稳定错误和脱敏诊断。

Windows control 始终监听 `127.0.0.1:0`，由 OS 分配端口，不实现固定或随机端口回退。staging
将固定 Node 二进制复制为 `MgReadNode.exe` 以便 Windows 排障识别，Node 版本/二进制身份不变，
也不使用 PATH。child 在 ready 前退出、无 stdout 或启动失败时，Supervisor 以稳定 fatal code
完成 Facade，并将仅含 code、phase、opaque fingerprint、耗时的记录追加到 Runtime 私有的 16 KiB
封顶 fallback TXT；没有 stderr、路径、异常、请求或插件内容。ready 后 child 退出同样作为 fatal
Facade diagnostic 发布；当前连接结束，且仅下一次显式调用有序冷启动唯一 Runtime，不做循环重试。

## 安装与依赖恢复

Runtime 测试独立覆盖 `.mgplugin` 安装器：

- package/lock v3 严格校验；旧 manifest 包稳定拒绝；
- 确定性 ZIP、安全路径/碰撞/符号链接/大小限制；
- registry tarball SHA-512 SRI 与完整 package 资源；
- 包内 `file:./packages/...`、optional、lock 已确定 peer 布局；
- dependency object store、并发下载合并、hardlink 与 copy fallback；
- 不可变版本、pending 冷激活、失败更新回退、延迟卸载和 mark-sweep。

安装器尚未通过生产 Facade 暴露下载/文件选择 invocation，因此主项目当前只展示 Runtime 健康
和已安装插件状态，不复制本逻辑。

## Fixture 与自动化证据

## Debug HTTP 检查页

Debug 构建由 Runtime-owned Facade 显式开关独立 HTTP 检查页。它监听临时 IPv4 LAN 端口，
只提供页面、状态、插件、搜索、发现和封面 probe 路由；内部 WS、health 与原始资源 URL 仍在
私有 loopback server。地址仅供复制，不经主应用构造或保存。无认证 LAN 风险与 Release 排除
由 [ADR-0023](../../../docs/architecture/adr/0023-debug-runtime-http-inspector.md) 固定。

[`protocol/fixtures/standard-node-plugin-v1.json`](../protocol/fixtures/standard-node-plugin-v1.json)
由 Node 与 Flutter 集成测试共享。当前验证层级：

| 层级 | 命令/位置 | 覆盖 |
| --- | --- | --- |
| Package/installer/manager | `node --test test/plugin-system.test.mjs` | package/lock、archive、依赖资源、SRI、hardlink/copy、optional、冷激活/回退、取消/超时、GC |
| Desktop Core | `node --test test/desktop-runtime.test.mjs` | ready、health、hello/ping/list、五个 source capability、shutdown、并发、背压、稳定错误 |
| Flutter ↔ Node | `npm run test:flutter-desktop` | singleton、真实 Process.start、Job Object、128 并发、完整内容链路、fatal 退出/无 stdout fallback、错误投影 |
| 官方模板 | `cd ../../../templates/mg_read_plugin_template && npm run verify` | tsc、多文件模块、本地 package/资源、命名 API、确定性 `.mgplugin` |

测试根均为临时目录，不读取真实用户数据。Runtime 只保留稳定 lifecycle code 和 Debug 有界内存
简单日志；不记录 keyword、结果内容、Cookie、token、路径、异常文本、HTTP body 或复杂对象。

## 发布边界

`npm run stage:flutter-windows` 只把编译 Core、固定 `MgReadNode.exe` 和 Node LICENSE 放入 Flutter
package 自身资产目录；`pubspec.yaml` 显式列出 `node/` 与 `dist/`，不能依赖
Flutter 目录资产的非递归行为。主项目不提供路径。Windows Debug 主应用构建已验证这些资产会
进入 `flutter_assets/packages/mgread_plugin_runtime/`，且包内 Node 能完成 ready/hello/shutdown
应答；这仍不是隐藏窗口、安装器、签名或 Release 包验收。对应平台交付前仍需分别完成 Windows
安装包、Android arm64 Javet 真机和 macOS arm64/x64 签名/公证证据。
