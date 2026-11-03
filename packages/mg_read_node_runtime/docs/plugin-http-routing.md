# 来源 HTTP 连接拒绝排查

本文记录当前 HTTP 路由边界、受控复现和现场取证方法。独立探针不读取 App 的已应用配置，
不能用电脑上的一次成功请求证明手机、旧安装包或历史请求正常。

## 2026-11-03 事件的证据范围

已知事件：`org.mgread.rehanman`、`source.getContent.v1`、
`trace_bc6d8f4d827eca50456657815491a69e`，底层为
`fetch failed -> ECONNREFUSED 127.173.137.161:40439`。

该信息证明一次 TCP 连接在调用进程所在的网络环境中被拒绝；它没有证明该地址属于代理、
Runtime 或站点，也没有证明某个进程退出。没有监听器、服务换端口、绑定错误或主动拒绝均需区分。
本次检查的 Windows App 持久诊断中未命中该追踪 ID，没有取得事发设备的代理配置、版本、
请求重定向或进程/端口快照，故历史根因保持未确认。

## 当前实现的完整调用链

1. Flutter `SourceContentInvocation` 经 `PluginRuntime.invoke` 按引擎路由，Node 来源进入所选
   Supervisor。桌面/Android Node 私有进程通过认证 WS；Android Javet 通过平台 channel 进入 Core。
2. `desktop-runtime.ts` 分派 `source.getContent.v1`，`PluginManager` 委托
   `PluginContentDispatcher.getContent`。Dispatcher 取得调用租约、按需加载 generation，
   `invokeLoadedPluginContent` 以 AsyncLocalStorage 保存 deadline、取消信号和 trace。
3. Rehanman 来源的 `content -> #entry -> #page` 发出
   `https://rehanman.com/webtoon/<数字 ID>` 请求；不是图片资源下载。结果中的图片只是随后使用的资源描述。
4. `plugin-manager-context.ts` 的 `ctx.http.fetch` 合并 deadline/取消信号，默认跟随重定向，
   传入 Runtime 的 `PluginRuntimeHttpClient`。
5. `ConfigurablePluginHttpClient` 选择 dispatcher：来源显式 `proxyMode: direct` 优先；
   否则用已配置的 `ProxyAgent`/`Socks5ProxyAgent`；否则用 `EnvHttpProxyAgent`。
6. HTTP(S) 代理客户端连接代理 URL 的 host/port，再以 CONNECT 请求目标；SOCKS5 同样先连接代理。
   系统 dispatcher 按目标协议和 NO_PROXY 决定代理/直连。直连的 host 来自当前请求 URL，
   域名经 DNS 解析后由 Node net/tls 建立 TCP；重定向可以改变下一跳 URL 和端口。
7. 失败经 `cause` 进入 `invokeLoadedPluginContent`，转成带来源、操作和有界因果链的
   `plugin_execution_failed` wire 错误，再由 Facade 抛出。App 的 `unhandled_platform_error`
   是根 isolate 未捕获错误的分类，不能据此推断 Android、Node 崩溃或网络根因。

当前 Core 控制/资源 listener 固定绑定 `127.0.0.1`，端口动态分配；它没有生成随机 `127.x.x.x`
主机的逻辑。Rehanman 初始详情 URL 使用 HTTPS 默认 443，源码没有 `40439`。
因此要确定谁选择了该端点，必须拿到实际代理 URL、每跳 URL 和 DNS/TCP 证据。
单独把站点域名解析到回环地址不会将初始端口 443 改成 40439。

## 代理配置和生命周期

- 桌面启动携带 `--use-env-proxy`，允许环境仅含 HTTP_PROXY/HTTPS_PROXY/NO_PROXY 等受控项；
  Windows 手动代理只补缺失值。外部系统代理端口后续变化不会自动修改运行中 Node 的环境代理 Agent，
  需要确认新配置并重启应用/受控 Runtime。不要以重启后恢复代替端口变化证据。
- Android `ConnectivityManager.defaultProxy` 经 `readSystemProxyEnvironment`/平台代理变化广播进入
  Flutter；`runtimeSourceProxyUri` 为普通 HTTPS 目标解析系统路由，再通过
  `runtime.pluginHttpProxy.configure.v1` 作为一个显式代理 URL 传给两种 Node 后端。
  这不是把完整的按协议环境和 NO_PROXY 交给 Node；广播未到、旧安装包无观察机制、
  VPN 自有 listener 换端口但未更新平台代理均需要现场核对。
- 自定义书源代理开关开启时，保存的 host/port 覆盖系统路径；系统代理变化不会替用户修改该配置。
  关闭自定义覆盖会恢复系统默认，并不保证直连。
- Node 进程 Supervisor 在 ready、health、hello 后重放保存的代理配置；Javet 使用同一 Core 控制方法。
  配置只影响后续请求，已开始请求继续使用原 dispatcher。旧 Agent 关闭等待现有请求结束，
  Runtime 停止则取消在途请求和未读响应。App 不拥有外部代理服务，重启 Runtime 不会启动该代理。
- Runtime 意外退出应结合 `node_exit`、`runtime_process_exited`、`transport_disconnected`、
  bootId/uptime 等生命周期证据。Core 返回一次 fetch 错误本身并不等于 Core 已退出。

## 已确认的独立缺陷与最小补丁

原系统代理路径只靠 NO_PROXY 的 localhost/127.0.0.1/::1，遗漏其他 IPv4 回环目标。
固定 Undici 7.29.0 只按主机/后缀/可选端口匹配，不支持 CIDR；补 `127.0.0.0/8` 或 `127.*` 无效。

补丁在系统 dispatcher 每次 dispatch 时对 URL 规范化后的字面量 `127.0.0.0/8`、`::1`、localhost
使用直连 Agent，覆盖重定向下一跳；其余系统规则保持交给 EnvHttpProxyAgent。
显式书源代理保持覆盖语义，仍允许代理端点自身位于整个回环段。
不增加 DNS 前置探测、异常吞掉或请求重试。

此补丁只修复 Node 系统代理对回环**目标**的路由；不修复失效代理**端点**，也不把 Android
已转成显式 URL 的系统代理改回完整环境规则。不能宣称本事件由此修复。

`test/plugin-http-routing.test.mjs` 使用真实 socket 证明：原代码的两种 NO_PROXY 配置和远端跳转到
回环目标均失败，补丁后直连；另分别复现系统/显式回环代理 listener 关闭后的 ECONNREFUSED，
通过 diagnostics_channel 确认连接参数，并验证配置新端口后成功。
`test/plugin-http-proxy.test.mjs` 通过真正的 `source.getContent.v1 -> ctx.http.fetch` 返回因果链，
确认 origin 未收到请求且 Runtime status 仍可响应。测试使用临时端口，不占用现场的 40439。

## 现场操作与判断

先在同一故障设备记录 App/插件版本、平台、Android 后端、时间、trace、来源/操作和完整 cause。
打开现有诊断详细捕获，复现一次后保存；同时保存 Runtime 页面中的状态和 Debug HTTP 的
`plugin.http`、`runtime.plugin.invocation`、`runtime.diagnostic` 日志。已有 HTTP debug 日志有目标
和状态，但失败通常只有异常类型，不能单凭它还原 TCP 代理选择；Debug listener 重启后日志会消失。
诊断详细记录和文件保存是独立开关；事后开启无法恢复已丢失记录。

同一时间取得三份配置：App 自定义书源开关及 host/port、OS 当前代理、实际 Node 生效环境/已下发 URL。
保存故障前后值及变更时间，不记录代理凭据、Cookie 或令牌。

Windows 可在故障设备执行：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 40439 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

再按 OwningProcess 查进程及代理自己的日志。Android 应在该手机/模拟器的网络环境中检查
`adb shell settings get global http_proxy`、`adb shell dumpsys connectivity` 中的默认网络代理，
以及可用的 `adb shell ss -ltn`；缺权限或 ss 不存在不等于没有监听。不要用电脑上的 127 地址探测手机。
Android 的全局设置值也不一定等于当前默认网络 ProxyInfo，应对照应用实际读值和代理 App 日志。

| 观察结果 | 可支持的判断 | 还需核对 |
| --- | --- | --- |
| 连接参数为代理 URL，40439 无监听，代理进程已退出 | 代理服务退出 | 退出时间、原因、App 是否仍持有旧配置 |
| 旧端口无监听，同一代理正在新端口监听 | 端口变化/配置过期 | OS 是否更新、广播是否到达、是否被自定义代理覆盖 |
| 正确进程只监听 127.0.0.1，而客户端连接 127.173.137.161 | 绑定地址不匹配 | 配置是谁生成的、是否同一网络 namespace |
| TCP 连接目的为回环 URL，且发生不应有的 CONNECT | 回环目标错误路由 | 原始 URL、每跳 Location、NO_PROXY 和所选 dispatcher |
| TCP 直接连接域名解析出的异常回环地址 | DNS/hosts/重定向方向 | DNS 答案、当前 URL/端口，不能只看最初 URL |
| 成功连接代理，代理随后返回 502/CONNECT 拒绝 | 代理已可达，失败在隧道/上游 | 代理日志、站点 DNS/TCP/TLS 和代理策略 |
| 直连公网 IP 失败，或收到站点 5xx/验证页 | 站点或直连路径问题 | 同设备按已确认的代理路径做有界对照；直连失败不能单独证明站点宕机 |
| bootId/uptime 改变且有退出/断连事件 | Runtime 重启 | 重放的代理是否最新，旧请求是否在重启前已开始 |

## 独立 TCP 探针

### 自动附加的失败上下文

来源 HTTP 请求在等待响应头期间失败时，现有异常链和 `plugin.http` 错误日志会附带
`HTTP request context`，包括平台/架构、Node/Runtime 版本、实际 Runtime 后端、初始/最后请求
origin、请求开始时的路由与代理端点、Undici 连接 origin/errno、socket 实际 TCP 尝试地址与端口、
请求 trace，以及 HTTP 客户端在请求
开始/失败时是否已关闭。原始 fetch 异常和底层网络 errno 保留为 cause，不增加重试。

`system-default` 表示交给系统 dispatcher 决策，不能直接等同于走代理；发生 CONNECT 时的
`proxyTunnelOrigin` 和 `tcpAttemptAddress`/`tcpAttemptPort` 提供实际路径证据。Undici 的
`connectionTarget` 可能是隧道内的逻辑 origin，不可当作物理 TCP 对端。没有连接事件明确标为 `not_observed`，可能
是复用连接或连接前失败，不表示没有发出请求。字段随每次请求冻结，代理切换不改写在途请求。
这些字段不包含 URL 用户信息、路径、查询、headers 或正文；此约束只针对新增上下文，
已有显式 Debug 请求日志和原始异常的保存策略不变。

App 的可复制错误报告和 `app.error.unhandled` v2 事件另附环境快照：已安装应用版本/构建号、
平台/OS、构建模式、所选 Node 后端、自定义书源代理偏好及端点。偏好标记为 `report_time`，
可能晚于 HTTP 请求开始；以异常中的请求快照为准。包元数据尚未加载或读取失败分别标记
`loading`/`unavailable`；VPN 状态没有可靠观测时标记 `not_observed`，不得据此认定未开启 VPN。

### 使用方式

在本 package 目录，把固定 `tools/node-v26.10.0-win-x64` 放到 PATH 前，先 `npm.cmd run build`，再运行：

```powershell
& tools/node-v26.10.0-win-x64/node.exe probes/diagnose-plugin-http.mjs https://rehanman.com/ system
& tools/node-v26.10.0-win-x64/node.exe probes/diagnose-plugin-http.mjs https://rehanman.com/ http://127.173.137.161:40439
& tools/node-v26.10.0-win-x64/node.exe probes/diagnose-plugin-http.mjs https://rehanman.com/ direct
```

每次只发一个 GET，含正常重定向，10 秒截止，不读取响应正文，不重试；输出 JSONL 的实际请求 origin、
CONNECT 方法、连接参数、DNS lookup、TCP 地址、状态与 errno 因果链。代理 URL 的凭据会从输出移除。
`system` 只读取当前 shell 环境，不读取 Windows 注册表，不代表运行中 App 的启动快照；
必须先用现场确认值准备环境，或显式传入现场代理 URL。不要将此独立进程当作 Android 真机或 App 验收。

Undici 官方观测接口见 [DiagnosticsChannel](https://github.com/nodejs/undici/blob/v7.29.0/docs/docs/api/DiagnosticsChannel.md)。
连接事件与请求只松散关联，连接池复用不保证每次请求都有新连接事件；并发现场应保留 trace、
request/CONNECT 和时间，必要时隔离一次请求再捕获。
