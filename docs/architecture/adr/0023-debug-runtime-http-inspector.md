# ADR-0023：Debug Runtime HTTP 检查页

- 状态：Accepted
- 日期：2026-08-25
- 决策者：MgRead 项目

## 决策

- Runtime 仅在 Debug 构建、用户显式开启后启动独立 HTTP 检查页；关闭、Runtime 重启和 Release 都不保留该 listener。
- 检查页监听 IPv4 `0.0.0.0:0`，展示 loopback 与本机网卡地址；按当前调试需要不做认证，同一网络可访问。
- 该 listener 只能提供 `/__debug` 及受限调试 API，绝不暴露 `/v1/rpc`、health、内部资源 URL、Cookie、token 或控制面。
- Android 维持唯一 Javet NodeRuntime/HandlerThread；Runtime 自有 loopback 资源数据面与非阻塞事件循环泵送用于正常代理资源，Debug listener 是额外可关闭的页面入口。
- Flutter 只能通过 Debug-only typed Facade 开关并读取可复制 URL，主应用不得构造端口、调用 Runtime HTTP 或实现书源调试逻辑。

## 后果

- 此 ADR 是 ADR-0004“所有端点仅 loopback”的 Debug-only 例外，不改变生产控制面、资源所有权或单 VM 约束。
- 无认证 LAN listener 会让同网段用户看到调试页返回的书源投影并触发书源请求；页面必须持续显示风险提示，且不得在 Release 中注册。
- 原始插件响应、HTML、图片正文、凭据、完整资源 token 与完整 URL query 不写入调试响应、日志或持久化存储。
