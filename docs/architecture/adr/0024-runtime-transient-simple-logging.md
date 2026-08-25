# ADR-0024：Runtime 仅保留瞬时简单日志

- 状态：Accepted
- 日期：2026-08-25
- 决策者：MgRead 项目
- 替代：[ADR-0016](0016-segmented-text-diagnostics.md) 的 Runtime 部分
- 依赖：[ADR-0004](0004-ws-http-transport.md)、
  [ADR-0023](0023-debug-runtime-http-inspector.md)

## 背景

Runtime 的分段 NDJSON 事件、span、capture session、附件、分页查询和详情 TXT 形成了复杂事件
体系。即使默认不捕获正文，持续写入 `runtime/diagnostics/events` 仍会在频繁启动和调用后累积
大量小型结构化记录。项目已经有 Debug 检查页的实时日志方案，继续维护两套体系没有产品价值。

## 决策

1. Runtime 删除结构化诊断 manager、registry、event/span、capture session、附件 spool、分段
   TXT store、retention、历史查询与对应 Runtime Facade capability。
2. Runtime 不再创建 `diagnostics/events`、`diagnostics/details` 或 `diagnostics/staging`。现有目录是
   可直接删除的遗留数据，不迁移、不导入实时日志。
3. Debug 检查页只在用户显式启用 listener 时保留有界进程内实时日志尾部。关闭 listener、停止
   Runtime 或达到容量上限时立即清空或淘汰旧项，不写盘。
4. 插件 `ctx.log` 只投影为有界、脱敏的简单文本记录。HTTP body、HTML、大 JSON、小说正文、
   Cookie、token、凭据、完整 query、路径和原始异常不得进入实时日志。
5. Flutter Supervisor 继续保留少量稳定启动/终止诊断和有界 fatal fallback，用于启动失败展示；
   它不是通用事件系统，不提供历史筛选、capture 或附件。
6. 日志丢失、listener 未启用、缓冲区满、浏览器断开或输出失败不得改变 Runtime 和插件业务结果。
7. 主应用现有 App-owned 诊断不由本 ADR 改写；主应用不再通过 Facade 查询 Runtime 历史事件。

## 后果

- Runtime 启动和调用不再产生持续增长的事件文件，磁盘占用与维护面显著降低。
- Debug 日志只覆盖当前启用窗口，Runtime 重启后无法回看历史；需要复现问题时必须先开启检查页。
- 复杂筛选、trace 关联、附件预览和持久 capture 被明确删除，不再作为兼容能力维护。
- 启动失败仍可由 Supervisor 的稳定诊断和 fatal fallback 定位，不依赖 Node 事件 store。

## 迁移与验收

1. 从协议 fixture、Core dispatch、Flutter Facade、主应用 Runtime 日志页签和文档中删除所有
   `diagnostics.*` capability。
2. 删除 Runtime `src/diagnostics`、对应测试与旧性能基准；保留并测试实时内存日志的容量、清空、
   脱敏和失败隔离。
3. 删除本机遗留 `runtime/diagnostics` 目录；新 Runtime 启动与核心调用后断言该目录不会重建。
4. 验证 Supervisor 的稳定 lifecycle/fatal 诊断仍可用，并确认 body、secret、路径和 raw exception
   canary 不出现在实时日志。
