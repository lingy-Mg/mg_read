# 原生 v2 实现契约

本文件描述当前实现。采用一个 worker 管理多个已启用插件、每库一个实例、串行内容调用；资源并发由插件 SDK 承担。
不做进程内卸载、多实例句柄、线程池内容调用或 v1 适配。控制面继续使用现有认证 HTTP RPC，媒体直接走插件 HTTP。

## 调用时序

1. App 启动已有 Windows EXE / Android 私有 `:mgread_native` Service；worker 绑定控制端口 `127.0.0.1:0`。
2. worker 读取安装元数据、完成此前标记的文件移除并隔离初始化崩溃来源；不加载插件动态库。
3. Facade 注入当前上游代理。已启用来源首次内容调用才校验二进制哈希、加载 v2 函数表、写入 loading 标记并 init。
4. init 创建插件 HTTP 客户端、缓存对象、单线程 I/O 执行器与 `127.0.0.1:0` 资源服务；返回实际端口及身份。
5. 串行 invoke 返回内容及插件已投影的 URL；认证 RPC 携带 resourceEndpoints，Facade 登记归属并强类型解码。
6. Flutter 图片/播放器直接 GET/HEAD 插件 URL；Rust worker 控制层不经手资源字节。
7. 管理变更关闭准入，等待短暂在途调用；超时停止旧 worker。调用 shutdown，随后确认进程退出，再冷启动。

## ABI 与内存

`mg_source_get_api_v2() -> *const SourceApi` 返回静态函数表，字段顺序见 `abi/lib.rs`：

| 函数 | 约束 |
| --- | --- |
| init(ptr,len) -> Buffer | 每库每 worker 成功一次；仅本地初始化；输入为 UTF-8 JSON |
| invoke(callId,ptr,len) -> Buffer | callId 非零且单调唯一；六个内容操作和内部 resource.inspect；串行 |
| cancel(callId) | 唯一允许与 invoke 并发的入口；快速、幂等；SDK 检查取消并中断网络 |
| shutdown() -> Buffer | 停止资源监听、取消传输、等待服务退出；幂等；调用前停止内容准入 |
| release(Buffer) | 分配该 Buffer 的库负责一次释放；宿主复制/解码后立即释放 |

输入只借用到返回，不能保留指针；不跨 ABI 传 Rust 容器、Future 或 trait。返回 `{ok:true,value}` 或
`{ok:false,error:{code,message}}`，最大 8 MiB。SDK 捕获 Rust unwind panic；abort、非法指针及死循环只能由进程隔离处理。
实例身份隐含在已加载库中，因此无需另设句柄或 create/destroy。业务无并发要求；多个资源流与 cancel 仍可并发。
shutdown 后不重新 init 同一库。即使初始化失败，库也固定到 worker 退出，不能把释放 Library 当作安全卸载。

init JSON：`{pluginId,generation,cacheDir,upstreamProxy:null|string,testMode:false}`。
宿主创建并校验专属 cacheDir（绝对路径、属于私有根、非链接），插件自行读写；SDK 哈希键、原子写、单项 8 MiB、
总额 64 MiB。generation 为每 worker/插件生成的 64 字符十六进制身份。testMode 仅验收入口开放回环上游。
init 成功值 `{pluginId,generation,port}` 必须原样匹配身份，port 1..65535。SDK 部分构造失败由 RAII 回滚；
外部库失败宿主尝试 shutdown 并禁用来源；下一次启用必须重启 worker。初始化崩溃保留旧版本并隔离失败候选。

## 资源服务

URL：`http://127.0.0.1:<port>/v2/source-resource/native/<pluginId>/<generation>/<randomToken>`。
令牌随机 256 bit，描述符只保存在插件内，30 分钟闲置失效、最多 4096 个；无 `?url=` 开放代理入口。
HLS 子资源共用根清单活动期限，下载进度续期；正常长视频不会因后半段尚未请求而使分片提前失效。
仅绑定 IPv4 回环，校验 Host、拒绝 Origin 和错误身份；未知/失效令牌 410。不得在日志/URL 中写上游头或凭据。
上游仅 HTTP(S)，限制重定向跳数，跨源重定向移除鉴权；控制和资源回环请求不经过用户上游代理。

- SDK 使用异步流和有界 16 路资源并发；慢消费者自然背压，断连释放上游响应和并发许可，shutdown 取消所有传输。
- 普通资源转发 GET/HEAD、Range/If-Range、上游 200/206/416、Content-Range/Length、Accept-Ranges、MIME、ETag。
  上游忽略 Range 时如实返回 200；不伪造 206。identity 编码避免 Range 与解压后字节偏移不一致。
- HLS 按最终重定向 URL 解析相对地址，改写主/子清单、URI 属性、分片、密钥和初始化片段为各自本地令牌。
  改写清单最多 1 MiB，重新计算 Content-Length/MIME，不沿用旧偏移/校验器；分片原样支持 Range。
  不支持 DRM 许可证或任意自定义 URI 协议；不能声称协议 fixture 通过就证明全部播放器兼容。
- 每个已加载插件占一个监听端口和一个 SDK I/O 线程；没有加载的插件没有这些开销。worker 重启关闭全部旧端口，
  随机 generation/token 即使端口被复用也使旧 URL 无效。多个原生插件共享 worker 的故障边界是当前简化取舍。
  管理任一原生来源会暂时中断其他原生来源资源，播放器需要重新解析；Node 服务不受原生重启影响。

HTTP/HTTPS/SOCKS5/SOCKS5H 代理在 init 注入；变更由 Facade 保存配置、重启 worker、首次使用重建客户端。
没有显式代理时沿用平台代理发现。代理凭据仅传给原生初始化，不进入公开资源结果。

## 管理、旧版本与刷新

导入只校验 manifest/归档/哈希，不调用 DLL。归档必须 abi:2，旧 v1 不再加载，应重新导入 0.2.0 参考包。
更新候选保持 pending，首次初始化成功才成为 active；失败禁用并保留上一 active 便于重新启用回退。
冷启动仅保留 active/pending 文件目录；成功切换后旧版本在下一个冷启动回收，保证不删除仍被加载的 DLL。
卸载控制响应表示已标记移除；公开 Facade 要等旧 worker 退出和新 worker 清理文件成功才返回。
“UI 发起”“停止准入”“进程退出/动态库消失”“磁盘清理完成”不是同一时刻。停止未确认则失败关闭，禁止继续启动。
启用/禁用、导入更新、卸载、缓存清除、代理变化共用重启路径；不重启整个 App。停机不合作最终由 Job/Service 杀进程。

URL 不持久化为内容身份。worker 重启后内容要通过原稳定 id 重新解析；小说缓存中的 descriptor 重新投影。
漫画沿用 sessionOnly/refreshable 的重新取章流程，音频沿用资源恢复流程；视频失败后的重试重新 loadEpisode，
保留播放器进度持久化。禁用/卸载不自动重新启用来源；刷新必须报告来源不可用。新增媒体来源仍需实际播放器验收。

## 保留通道与验收

当前 HTTP 控制 RPC 保留进程隔离、Windows Job、Android Service 和现有取消。Dart FFI 或 flutter_rust_bridge
直接嵌入 App 会改变隔离边界；若仍在 Service 中则依然需要 IPC，且不能替代 Rust 到动态库的 C ABI。
没有性能测量支持本次更换桥。资源字节已绕过控制 JSON，先分别测空 RPC p50/p95、JSON 编解码大小/时间、真实搜索/详情、
图片首字节/总时长、音视频吞吐和拖动延迟，记录冷/热缓存、代理、设备、重复次数，禁止凭桥名称断言速度。

验证分层：宿主/SDK/来源 cargo tests；真实 DLL worker 的 tools/acceptance.py；Facade 的 native/hybrid/resource routing tests；
再执行 Windows App 和 Android 私有 Service 冷启动、停止/重启、图片、音频拖动、MP4/HLS 播放。
Android Runtime 的 main Manifest 引用仅开放 127.0.0.1/localhost 明文的配置，合并 Manifest 要保留它；
仍须由真实 HttpClient/MediaKit 请求回环服务，跨进程可达性不能只凭编译推断。
配置依据 [Android Network Security Configuration](https://developer.android.com/privacy-and-security/security-config#CleartextTrafficPermitted)。

## 文件归属与实施顺序

| 顺序 | 主要文件 | 边界 |
| --- | --- | --- |
| 1 | `abi/lib.rs`、`src/native.rs`、`src/catalog.rs`、`src/dispatch.rs`、`src/lib.rs` | v2 函数表、延迟初始化、版本目录及 worker 生命周期 |
| 2 | `sdk/src/{lib,cache,http,resource,hls}.rs` | 静态链接到插件的通用实现；宿主无 HTTP/缓存回调和资源搬运 ABI |
| 3 | `plugins/sources/aisishuwu-native/src/` 及其 build/package 脚本 | 参考来源迁移、缓存键升级、v2 归档 |
| 4 | `mgread_plugin_runtime/lib/src/{source_resource_url,native_supervisor,native_supervisor_transport,hybrid_supervisor,plugin_content_decoder,plugin_invocation}.dart` | 统一 URL 归属解析、认证端点登记、强类型结果和重启准入 |
| 5 | Flutter 两个漫画数据读取适配器、Runtime Android Manifest/网络配置 | 非持久资源断连后单次重新取章；私有 Service 回环明文策略 |
| 6 | ABI fixture、SDK HTTP 测试、Facade 测试、设备/播放器验收 | 按层验证，记录构建与实播之间的剩余边界 |

与宿主转发资源相比，本实现省去跨 ABI 传输字节、宿主缓存和插件解码的交错所有权；代价是每个已加载插件
增加一个端口、一个 I/O 线程与一份客户端。HTTP/HLS 兼容细节集中在静态 SDK，插件维护者无需重复实现。
SDK 与插件一同升级，无法只升级宿主便修复已发布插件中的媒体逻辑；这是明确的维护取舍。

开发期整体切换 v2，不做运行时 v1 回退。来源升级失败保留上一个 active 版本，再次启用通过重启回退；
首次安装没有旧版本时保持禁用并报告错误。若引擎改造需要回退，应整体回退宿主、Facade、SDK 与对应来源包，
停止 worker 后重新导入匹配版本，不混用 ABI 版本；先保存用户库数据，不能把删除全 App 数据作为回退步骤。

当前验证记录见 [V2_ACCEPTANCE.md](V2_ACCEPTANCE.md)。
