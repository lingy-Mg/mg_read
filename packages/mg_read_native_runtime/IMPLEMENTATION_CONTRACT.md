# 原生 HTTP 数据源实现契约

当前实现采用一个共享 Rust worker 托管全部原生来源。未启用来源不加载 DLL/SO；已启用来源首次内容调用或资源解析时初始化。
插件各有一个动态回环端口，内容与资源都走 HTTP。没有每来源进程、WebSocket 内容调用、跨 ABI invoke/cancel/release，
也没有资源的内存令牌表。参考来源版本为 0.3.0；开发阶段直接切换初始化 ABI 3，不兼容旧归档。

## 调用时序

1. Windows EXE / Android 私有 `:mgread_native` Service 启动一个 worker；它只读取安装元数据，不执行插件。
2. Facade 首次使用某来源，经认证 worker 管理 HTTP 调用 `plugins.native.initialize.v1`，同一来源单飞初始化。
3. worker 校验 enabled、manifest 和二进制哈希，持久化 loading 标记，加载库并调用唯一的 `mg_source_init_v3`。
4. 插件创建 HTTP 客户端、缓存对象、一个异步 I/O 执行器与 `127.0.0.1:0` listener，返回实际端口和状态。
5. Facade 直接 POST 插件 `/invoke`，请求 `{method,params}`，响应 `{ok:true,result}` 或 `{ok:false,error:{code,message}}`。
   方法名和内容语义保持 `source.search.v1` 等现有六个方法。SDK 校验能力、身份、预算，Facade 完成强类型解码。
6. 图片/播放器请求插件 `/v1/source-resource/<payload>`；worker 不转发业务响应或资源字节。
7. 管理变更关闭新调用准入，短暂等待在途请求，然后 HTTP `/shutdown` 并确认 worker 退出，再冷启动。

Node 的业务通道与资源代理保留。统一 Facade 不向业务层暴露初始化端点、控制 token、进程或 worker 世代。

## 最小初始化 ABI

唯一布局见 `abi/lib.rs`：`mg_source_init_v3(const uint8_t *json, size_t length) -> InitResult`。
`InitResult` 为固定 C 布局 `{uint32_t version,status; uint16_t port,reserved;}`，version=3、status=0 表示成功，
port 必须非零，reserved=0。失败 status=1；不返回需要另一方释放的内存。输入 JSON 仅在调用期间借用，插件不得保留指针。
这是一次配置字节借用与固定大小结构体返回，不能称为完全没有 ABI；后续没有跨库堆内存归属或释放协议。

配置字段：`pluginId, sourceName, capabilities, generation, controlToken, cacheDir, upstreamProxy, testMode`。
宿主创建并校验专属绝对缓存目录（位于私有根、非链接）；插件自行读写。SDK 哈希缓存键、原子写、限制缓存总量；
仅缓存写入/删除有短锁，不锁住整个内容请求。generation/token 只用于当前端点登记和控制认证，不放进资源身份。
上游代理接受 HTTP/HTTPS/SOCKS5/SOCKS5H，变更后重启 worker；没有覆盖时沿用系统发现。回环控制客户端始终直连。

init 成功后不再调用该库的 ABI。关闭通过认证 HTTP 完成；停止监听、取消内容及资源传输、释放连接和任务。
初始化构造失败由 SDK 的 RAII 回滚；宿主禁用失败来源。初始化 abort/卡死不能靠网络取消，超时终止整个 worker；
loading 标记在冷启动隔离来源，并保留此前 active 版本。动态库始终固定在进程中，即使 init 失败也不手动卸载。

## HTTP 并发和取消

每个内容请求独占一条 HTTP 连接。SDK 使用异步 handler，多个等待上游的请求可同时推进，不使用全局串行 invoke 锁。
Dart 取消或超时关闭本请求连接；服务器掉线后丢弃 handler 和上游 future。没有网络请求 ID、cancel 路由或取消确认报文。
SDK 真实 TCP 测试同时挂起两个上游，关闭其中一个并验证只有对应上游断开，另一请求和新请求仍可用。

HTTP 本身不会中断插件里的同步死循环或阻塞计算。来源处理器应异步等待网络，避免长时间占住执行器；需要 CPU 密集处理时
另行设计有界计算任务及取消。当前少量线程足够支持 I/O 并发；不引入通用线程池 ABI。最终故障边界仍是整个 worker。

## 持久描述与统一资源路由

路径与 Node 对齐：`http://127.0.0.1:<port>/v1/source-resource/<base64url-json>`。
原生 payload 为 `{version:1,engine:"native",pluginId,request:{kind,url,headers?,...}}`；Node 的缺省 engine 为 node。
描述完整放在 URL 中，无 30 分钟期限、4096 项注册上限或进程内资源表。HLS 的子资源同样生成完整描述。
Base64URL 可逆，不提供加密或身份认证；不能把编码后的上游鉴权当成已隐藏。保留 Node 现有本地可信资源模型，
不开放 `?url=` 路由，不接收 file 等上游协议；检查 Host、Origin、归属和头字段，不记录完整资源 URL。

动态端口本身不能跨重启继续使用。`SourceResourceResolveInvocation` 由唯一解析器识别引擎/来源，Hybrid 核对安装归属，
再由所属引擎确认来源可用、使用当前 listener 重建 URL。旧 URL 只是资源描述载体，其端口不被直接信任。
原生内容结果仍须匹配本次认证初始化登记的插件和端口；响应还要属于当前 worker 世代。
封面、漫画下载及音视频来源适配器在读取前调用此入口。保存的封面描述在 worker 重启后无需再次查询详情即可下载。
已缓存图片字节照常使用；在途 HTTP 会中断。漫画保留一次刷新重试；音频错误恢复重新加载所选曲目并恢复进度，
视频重试重新加载所选集。插件禁用/卸载时解析明确失败，不自动启用。上游自身的签名过期仍可能需要来源重新取内容。

- GET/HEAD、Range/If-Range、200/206/416、Content-Range/Length、Accept-Ranges、MIME、ETag 由插件 SDK 处理。
  上游不支持 Range 时保持 200，不伪造可拖动能力；identity 编码避免字节偏移错位。
- HLS 按最终重定向地址解析主/子清单、URI 属性、分片、密钥和初始化片段，重写为本地完整 payload。
  重写清单重新计算长度/类型，不保留失效的范围和校验器；分片流保留范围语义。跨源重定向移除原源鉴权。
- 资源流最多 16 路同时传输；慢消费者施加背压，断连释放上游和许可。每个已初始化来源一个端口和一个 I/O 线程；
  未加载来源无这些开销。全部原生来源共享一次 worker 重启的中断范围，Node 不受影响。
- 源级图片变换仍属于插件；当前基础 SDK 不实现 Node 私有 handler 或 DRM。

## 生命周期、迁移及取舍

启用/禁用、导入更新、卸载及代理改变通过统一 worker 冷重启生效，无须重启 App。缓存清理先确认旧进程退出，
在尚未加载任何插件的新 worker 删除缓存，避免 shutdown 响应与仍在写入的任务竞态。
更新先安装 pending，首次 init 成功成为 active；失败禁用并保留前 active。下一次冷启动回收旧版本文件。
卸载先标记 removing，再结束进程，新 worker 清除目录；公开 Facade 在清理成功后返回。
UI 发起、关闭准入、进程退出（动态库卸载）、文件删除是不同状态。停止无法确认时禁止继续重启或删除；
合作关闭超时最终由 Windows Job / Android Service 停进程，不能把释放库句柄当作安全卸载。

相较宿主转发资源，本方案少一层 Rust 字节搬运，插件自行拥有上游行为，代价是每个插件携带 SDK/监听器并共享进程故障。
没有测量据此断言更快或更省电。空闲异步 listener 不主动轮询；额外 socket/JSON 成本、线程栈和手机能耗仍需测量。
不引入 Dart FFI/flutter_rust_bridge：直接 FFI 会改变进程隔离；仍在 Android Service 中就仍需 IPC。
即使日后换 Dart↔worker 通道，动态插件仍需这个最小初始化边界。

## 文件归属与验证

| 阶段 | 文件所有者 | 验证/回退 |
| --- | --- | --- |
| 初始化与管理 | abi、src/native/lib/dispatch/catalog.rs | ABI fixture、失败隔离、冷更新、卸载；回退整个宿主和匹配插件包 |
| HTTP 来源 SDK | sdk/src/lib/server/http/cache/resource/hls/validation.rs | 真实 socket 并发、断连、HEAD/Range/HLS/背压、缓存隔离 |
| 参考来源 | aisishuwu-native/src 与 build/package | 异步来源与离线 fixture；0.3.0 两平台归档 |
| 统一 Facade | native_supervisor_transport、source_resource_url、hybrid_supervisor、plugin_invocation | typed decode、旧描述重绑、引擎归属、生命周期 |
| Node 解析入口 | desktop-source-control-dispatch、desktop-runtime、source-resource-token | 现有 Node 来源和资源测试；已有 URL 格式继续有效 |
| 实际消费者 | 封面 persistence、comic reader、audio/video data source、bootstrap | 延迟图片、重启后重新播放/拖动；根版本按脚本升级 |

单元/协议、Facade、真实 worker、App/设备与播放器验收分别记录。Windows 跨进程回环已有真实 worker/Facade 证据；
Android 需启动默认双引擎 APK，在真实私有 Service 冷启/退出后由主进程 HttpClient 与 MediaKit 请求插件端口，检查合并 Manifest
的本地明文配置；编译不能替代该验收。媒体验收使用真实图片、音频拖动、MP4 拖动及 HLS 子清单/分片/密钥/初始化片段。
性能记录同设备、同网络/代理、冷/热缓存下的空 HTTP p50/p95、JSON 编解码、搜索/详情、图片首字节/总时长、
音视频吞吐/拖动延迟和固定时长播放/空闲能耗；当前没有能耗或桥接对比结论。
