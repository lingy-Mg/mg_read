# ADR-0004：WS 控制面与 HTTP 数据面

- 状态：Accepted
- 日期：2026-08-13
- 决策者：MgRead 项目

## 背景

Flutter 与 Node 需要双向调用：Flutter 调用插件，插件又可能等待数据库、Cookie、文件或未来原生能力。同时小说正文通常较小，漫画、图片、ZIP、下载和未来媒体可能很大，需要 Range、取消与背压。

可选方案包括平台通道、stdio、单一 WebSocket（二进制也走 WS）、HTTP 轮询、gRPC 或 WS+HTTP 分离。

## 决策

- Flutter 与 Node 的所有业务控制调用使用一条可重入的全双工 WebSocket。
- WS v1 使用 UTF-8 JSON 小消息，固定 request/response/error/event/cancel 五种 envelope。
- 所有二进制与超限文本统一经 Node loopback HTTP，Flutter 不直接访问源站。
- HTTP 支持 GET/HEAD、Content-Length、Content-Type、ETag、Range、取消和背压。
- 上游不支持 Range 时先安全落盘，再由本地稳定文件提供 Range。
- 小说正文可在协商 `maxInlineBytes` 内走 RPC，超限时使用文本 `ResourceHandle`。
- 桌面与 Android 使用完全相同的 WS/HTTP 业务协议；Javet/stdio 只处理启动生命周期。
- 首版端点只绑定 loopback，不做通信鉴权；该风险由 ADR-0002 接受。

## 后果

正面：

- 双向 RPC 能在 Flutter 等待插件时处理嵌套 `host.*`，不需要平台专属回调协议。
- HTTP 天然提供成熟的流、Range、HEAD、缓存头和消费者取消语义。
- 大资源不进入 JSON/Base64，降低复制、GC 和 WS 队头阻塞。
- 阅读器和未来播放器可以消费标准本地 HTTP 资源。

代价与风险：

- 需要同时管理 WS/HTTP 两个通道、bootId、句柄 TTL 和重连状态。
- WS handler 必须真正并发分派，连接级锁会造成嵌套 RPC 死锁。
- loopback 无认证意味着同机攻击面未消除；随机句柄不等于授权。
- 临时句柄跨 Runtime 启动失效，持久文件必须由数据库重新生成句柄。
- 上游无 Range 时首次随机访问需要等待落盘。

## 被拒绝的方案

- **全部走 WS**：大 frame 与二进制复制会阻塞小 RPC，Range/播放器语义需要自造协议。
- **Flutter 直接下载二进制**：分裂插件 Cookie/header/重试/缓存策略，并绕过 Node 数据来源边界。
- **stdio 承载业务**：桌面可用但 Android 不自然，背压/重入/资源语义不足。
- **只用 HTTP 轮询**：反向宿主调用和事件需要复杂长轮询，重入不清晰。
- **首版 gRPC**：代码生成和二进制 RPC 仍不能替代大媒体 HTTP Range，增加跨 Javet 依赖而收益不足。

## 变更条件

只有协议基线表明 WS JSON 小消息或 loopback HTTP 是已测瓶颈，或者安全/平台政策要求改变传输时，才可提出替代 ADR。新方案必须保留双向重入、取消、幂等、Range、背压、跨平台一致性和迁移兼容。

## ADR-0008 职责澄清

本 ADR 的 WS 控制面、HTTP 数据面、Range、背压和跨平台一致性结论保持 Accepted。自
ADR-0008 起，它们是 `mg_read_runtime` 的内部实现：主项目不得创建 Runtime Client 或
直接处理 wire protocol。本文历史上关于 Flutter `host.*` 回调、Flutter 数据库提交和
反向宿主 dispatcher 的部分由 ADR-0008 取代；插件所需存储、Cookie、文件和未来平台
能力改由 Runtime 自有服务实现，不向主项目注入 callback。
