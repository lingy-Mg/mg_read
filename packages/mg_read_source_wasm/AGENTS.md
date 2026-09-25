# Wasm 数据源适配器

本 package 拥有无站点知识的 ABI v1、实例与请求生命周期、消息和 HTTP 上限；`MgReadPluginContext` 仍从
`@mgread/source-api` 引用。网络、资源代理和公开错误只使用该 Context；不得读取 Runtime 私有状态。

- 适配器随来源构建内联，不是 Runtime 新进程或动态模块 loader；Wasm 只在现有 V8 内运行。
- ABI 变化同步 README、index.d.ts、独立 adapter 测试和 `aisishuwu-wasm` 的真实二进制测试。
- 运行固定 Node 的 `npm.cmd test`；来源回归和设备验收在参考来源目录拥有。
- 输入/输出各 8 MiB、HTML 4 MiB、请求并发 4、请求总量 128；Rust 参考产物的线性内存上限为 64 MiB。
  同步 guest 指令不能抢占，不能把本适配器描述为不可信代码隔离沙箱。
