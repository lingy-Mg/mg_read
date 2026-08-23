# 全局诊断接入规范

适用于任何新增或修改用户操作、异步加载、缓存、持久化、Runtime Facade、后台任务和性能关键
链路。它是所有后续开发者与 AI 的必做清单；实现前同时阅读根 `AGENTS.md`、
[全局日志专题](../architecture/14-global-diagnostics-logging.md)和
[ADR-0016](../architecture/adr/0016-segmented-text-diagnostics.md)。

## 实施顺序

1. 明确 owner：一次用户操作、跨边界调用或长任务只能有一个 owner span，并在
   `success`、`error`、`cancelled`、`timeout`、`overloaded` 中恰好选择一个终态。阶段耗时使用
   child span 或既有阶段 schema，不能另起第二个 owner。
2. 先在 `lib/core/diagnostics/src/diagnostic_registry.dart` 复用或注册稳定、版本化的事件 schema；
   字段只允许低基数状态、计数、字节、耗时和稳定错误码。字段语义变化时提升 schema version，
   不能临时拼 event name 或 attributes。
3. feature 只能消费注入的窄 `DiagnosticsManager`/query/capture port，并用 lazy attributes 调用
   `emit`、`startSpan` 或 `runSpan`。Widget、页面和业务 adapter 不得直接访问 TXT、sink、路径、
   Runtime transport 或日志配置。
4. 只记录稳定 route、状态、数量、字节、耗时、缓存命中投影和稳定错误码。不得记录书名、作者、
   搜索词、正文、HTTP body、HTML、大 JSON、用户输入、完整 URL/query value、Cookie、token、
   Authorization、绝对路径、原始异常或堆栈。
5. 高频 frame、滚动、chunk、分页条目和循环只能做有界窗口聚合；超过性能基线使用
   `performance.slow` 或受控等价 schema，不能逐项写日志。
6. Runtime/插件链路保持同一 trace：Flutter 仅调用公开强类型 Facade；Runtime、插件 `ctx.log` 与
   `ctx.http` 使用其所属 Runtime 规范。主应用不得读取 Runtime 日志文件、转发 raw stderr 或自建
   transport。

## 控制台与查看方式

- 非 Release 构建中，中心 `AppDiagnosticsService` 会将关键用户流程的 start/terminal 与所有
  warn/error/fatal 转成单行摘要，实时镜像到 VS Code Debug Console，前缀为 `[MgRead]`。完整 JSON
  envelope 只保留在 TXT/专用查看器，不得输出到底层控制台。feature、Widget、插件和 Runtime adapter
  不得自行使用 `print`、`debugPrint`、`developer.log`、`console.*` 或写日志文件。
- 应用内查看入口固定为“我的 → 关于与其他 → 调试日志”；其中 App 与 Runtime 是各自受限、分页的
  数据源，不能通过文件路径绕过 Facade。
- 控制台和 TXT 默认都是 `keyOnly`，不是内容抓取开关。正文/HTTP 详情只能经专用查看器的显式、
  有时限且有 allowlist 的 capture session 获取。

## 交付门禁

- schema 或埋点变更必须有受影响的自动化测试，覆盖 start 与唯一终态，及适用的取消、超时、错误或
  过载语义。
- 至少添加或更新 secret/content canary，断言敏感值不出现在事件、持久化 TXT、查看器 preview、
  导出和 Debug Console。
- 验证日志 sink、控制台镜像和持久化失败不会改变业务结果；性能关键链路还要报告耗时/队列/drop
  证据，不能把输出的主观“感觉更快”当作结论。
- 交付报告单列“日志/canary/性能证据”和未执行项。只改文档时执行相对链接、格式与 diff 检查；
  改代码时仍执行根 `AGENTS.md` 要求的静态与受影响自动化检查。
