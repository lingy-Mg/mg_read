# 原生数据源 Runtime

本 package 拥有独立 Rust 宿主、C ABI、原生安装与资源服务，不依赖 Node、V8 或 Flutter 业务状态。
ABI 类型只定义在 `abi/lib.rs`；来源通过该 crate 消费，输入与缓冲区只在一次调用内借用。
HTTP 与取消归宿主；源码插件在 worker 线程同步进入 C ABI，宿主网络 I/O 由 Tokio 驱动。
动态库在 worker 生命周期内持有，不在在途请求中卸载。更新及卸载由冷重启完成。
验证使用 `cargo test --locked`、真实冷安装和根 App 的 native-only 双平台构建；纯 Rust 成功不代表 App 验收。
