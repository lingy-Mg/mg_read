# 原生数据源 Runtime

本 package 拥有 Rust worker、安装目录、C ABI 和静态链接的来源 SDK，不依赖 Node、V8 或 Flutter 业务状态。
`abi/lib.rs` 是唯一 ABI 定义；`sdk/` 属于插件二进制，拥有上游 HTTP、缓存和资源 HTTP 服务。
宿主不提供 HTTP/storage 回调，不搬运媒体字节。每个动态库在一个 worker 中只有一个实例。
只有已启用来源的首次内容调用可以加载动态库；导入、列表、冷启动只检查元数据。
init/invoke/shutdown 串行；只有 cancel 可以并发进入。SDK 的单线程 I/O 执行器可以并发传输资源。
启停、更新、卸载、缓存清理及代理变更由 Facade 关闭准入、确认旧进程退出后冷重启；动态库始终固定在旧 worker 中。
ABI v1 不兼容，重新导入 v2 归档。初始化失败禁用来源；初始化期间崩溃由持久化 loading 标记隔离。
直接验证：宿主、sdk、参考来源分别 `cargo test --locked`；再执行真实 DLL worker 与 Dart Facade 测试。
协议测试不能替代 Windows/Android App、图片和播放器验收，Android 仍需真实私有 Service 退出证据。
