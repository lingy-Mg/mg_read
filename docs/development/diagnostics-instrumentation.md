# 日志与诊断接入规范

适用于新增或修改 App 用户操作、异步加载、缓存、持久化、后台任务，以及 Runtime 简单日志。
实现前同时阅读根 `AGENTS.md`、[日志专题](../architecture/14-global-diagnostics-logging.md)和
对应 ADR：App 使用 ADR-0016，Runtime 使用 ADR-0024。

## App 接入

1. 一次 App 用户操作或长任务只有一个 owner span，并在
   `success/error/cancelled/timeout/overloaded` 中恰好选择一个终态。
2. 在 `lib/core/diagnostics/src/diagnostic_registry.dart` 复用或注册稳定 schema；字段只允许
   低基数状态、计数、字节、耗时和稳定错误码。
3. feature 只消费注入的窄 `DiagnosticsManager`。Widget 不直接访问 TXT、路径或 Runtime transport。
4. 默认不得记录书名、作者、搜索词、正文、HTTP body、HTML、大 JSON、用户输入、完整 URL、
   Cookie、token、凭据、绝对路径、原始异常或堆栈。
5. 详情只在 App 专用查看器显式 capture 且命中 allowlist/预算时惰性构造。
6. 高频 frame、滚动、chunk、分页条目和循环只能做有界聚合。

## Runtime 接入

1. 不注册结构化事件，不创建 span/capture/attachment，不实现 `diagnostics.*` capability，也不
   写 `runtime/diagnostics`。
2. 插件简单文本只经 `ctx.log` 进入 Debug 有界内存尾部；Runtime lifecycle 使用稳定安全文案。
3. Debug listener 未启用时不保留日志；关闭 listener、Runtime 停止或容量满时清空/淘汰。
4. 日志先脱敏、后截断，不读取或复制 HTTP body、HTML、JSON、正文、query value、凭据、路径或
   raw exception。
5. 日志 observer、浏览器、缓冲或输出失败不得改变 capability 结果。

## 交付门禁

- App 变更覆盖 owner span 唯一终态、secret/content canary、禁用详情 supplier 和写入失败隔离。
- Runtime 变更覆盖实时日志容量/清空、secret/query/body/path canary、observer 失败隔离，并断言
  启动与调用后不创建 `runtime/diagnostics`。
- 非 Release 的 App Debug Console 仍只能由中心 App 诊断镜像输出；feature/Widget/插件不得使用
  `print`、`debugPrint`、`developer.log`、`console.*` 或自行写日志文件。
- 交付报告分开列出 App 持久诊断与 Runtime 瞬时日志证据；未执行的平台和真实运行如实说明。
