# 08 可靠性、可观测性与测试

## 可靠性原则

1. 每个 Runtime capability 只有一个明确终态：成功、失败、超时或取消；内部断线不能留下
   永远等待的 Future/Promise。
2. Runtime Store 的持久状态优先于易失运行状态；Facade 重连和应用重启都从 Runtime
   Store 与 snapshot 重建，主项目不维护影子权威数据。
3. 写操作以幂等键、Runtime Store 事务、临时文件和原子提交保证可重试；读取只有声明
   幂等时自动重试。
4. 所有队列、重试、缓存、日志和恢复扫描都有界。
5. 错误先归一化为稳定码，再由主项目映射为用户可行动状态；插件原始异常不能直接显示
   或持久化。
6. Runtime 的失败不以主项目回调兜底。未实现能力返回 `unsupported`，来源不可用不伪装
   为空数据。

## 故障域

| 故障域 | 例子 | 隔离与恢复 |
| --- | --- | --- |
| Flutter 页面 | 页面销毁、旧请求回调、路由中断 | request generation/取消；从 Facade 投影重建 |
| Runtime Facade | 调用取消、版本不兼容、受控连接错误 | 稳定错误、诊断投影；不向主项目泄露 wire 状态 |
| Runtime Store | 迁移失败、事务冲突、磁盘满 | Runtime 事务/恢复、只读诊断和明确 `disk_full` |
| 内部 WS 控制面 | 断线、非法 frame、重复 ID | Runtime 结束在途调用；同 bootId 有界重连并 snapshot |
| 内部 HTTP 数据面 | 上游中断、消费者取消、Range 不一致 | 背压/取消传播；检查点和 ETag 验证后恢复 |
| Node Runtime | 启动失败、崩溃、事件循环卡死 | Runtime Supervisor `failed`；首版要求重启应用，不起第二 VM |
| 单个插件 | 格式错误、限流、加载失败 | 插件级错误/队列/断路；新版本失败回滚旧版本 |
| 源站 | 超时、认证、限流、内容变化 | origin 级退避；`interaction_required`；版本核对 |
| Runtime 文件存储 | `.part` 残留、摘要错误、记录丢失 | Runtime 启动恢复、原子提交、损坏标记和重新获取 |
| 平台生命周期 | Android 杀进程、桌面强退 | Runtime deadline flush；下次 Runtime 启动恢复 |

单 VM 只隔离异步任务状态，不隔离插件的同步 CPU 故障。事件循环 watchdog 能发现延迟但
不能可靠抢占死循环，这是架构已接受限制。

## 重试与 UI 错误

- 默认不重试；每个 capability/错误组合在 Runtime Schema 中明确是否允许。
- 只自动重试幂等读取、Runtime 内部连接建立和可验证的 Range 续传。
- 写操作断线后由 Runtime 查询自身权威状态，再使用原幂等键重试。
- 使用有限次数的指数退避、抖动和总 deadline；尊重 `retryAfterMs`。
- `invalid_request`、`version_incompatible`、`unsupported`、`plugin_disabled`、
  `interaction_required` 默认不自动重试。
- 应用重启不会清空 Runtime 任务的 attempt/checkpoint；过期 deadline 不跨重启复用。

主项目 Application 层只将 Runtime 的稳定错误映射为 UI 语义：

| UI 语义 | 用户动作示例 |
| --- | --- |
| `retryableTemporary` | 重试、稍后再试 |
| `runtimeUnavailable` | 查看诊断、重启应用 |
| `pluginUnavailable` | 启用、重新安装、回滚或选择其他来源 |
| `interactionRequired` | 首版说明能力暂不可用 |
| `contentUnavailable` | 返回目录、选择其他章节/来源 |
| `storagePressure` | 通过 Runtime capability 打开存储管理 |
| `incompatible` | 更新应用/插件或恢复兼容版本 |
| `cancelled` | 通常不弹错误；保留当前稳定页面状态 |
| `unknownSafe` | 显示 trace ID 和诊断入口，不显示原始堆栈 |

刷新失败且已有数据时保留现有 UI 数据并标记陈旧；首次加载失败显示明确错误状态。UI 不
应猜测插件、文件、缓存或数据库细节来决定恢复步骤。

## 结构化日志与指标

日志采用稳定 JSON 事件模型。Runtime 负责插件、Store、通信和平台日志；主项目只记录
UI/路由投影。允许字段包括 UTC 时间、固定 component/event、`bootId`、`traceId`、
技术 request/job ID、plugin ID、capability、队列类别、耗时、聚合字节、稳定结果码、
平台/Runtime/协议版本。

禁止记录正文、漫画内容、搜索词、书名/作者、用户标识、Cookie、令牌、Authorization、
凭据、验证码、Store 行内容、完整 URL/query、request/response body、任意插件对象、
未脱敏堆栈和绝对用户路径。

- 默认日志位于 Runtime 自有的有界环形文件/Store 摘要，按大小和时间轮转。
- 诊断导出由用户显式触发，Runtime 导出前再次脱敏并声明包含范围。
- 首版不默认上传远程遥测或崩溃数据。未来远程采集需要隐私说明、用户选择和单独决策。
- release 构建不依赖 console 作为唯一诊断渠道；Runtime 结构化接收桌面 stdout 并有界保存。

低基数指标至少覆盖 Runtime 启动/关闭/失败、Node 事件循环/RSS/heap、内部 WS/HTTP、
队列与限流、缓存/下载/Range/恢复、Runtime Store 事务/迁移、以及 Flutter build/raster
和页面关键阶段。不得把 remote ID、资源 URL、书籍 ID、trace ID 或错误自由文本作为
指标标签。

## Trace 与诊断界面

- Runtime Facade 或后台任务入口创建 `traceId`。
- Facade、Internal Bridge、Node handler、插件、`ctx.http`、资源流和 Runtime Store
  事务继承同一 trace；没有 `host.*` span 或主项目数据库事务。
- 性能诊断分解 queue wait、network、parse、Runtime Store 与 UI commit，避免把总耗时
  错误归因给协议。

主项目诊断页面只读展示 Runtime Facade 投影：应用/平台/Runtime/Javet/Node/协议版本、
Supervisor 稳定状态、bootId 的短显示、内部 readiness、队列/内存概要、插件版本/回滚
状态、下载/缓存/恢复摘要、Runtime Store schema 版本、trace ID 和用户恢复动作。它不
能执行任意脚本、SQL、URL 或文件路径，也不能直接查询 Runtime Store。

## 自动化测试分层

```mermaid
flowchart TB
    PLATFORM["Runtime platform smoke"]
    RUNTIME["Runtime integration and fault tests"]
    CONTRACT["Runtime Facade + shared schema fixtures"]
    APP["Flutter UI / application tests"]
    UNIT["Runtime Store, scheduler, plugin and UI pure tests"]
    PLATFORM --> RUNTIME
    RUNTIME --> CONTRACT
    CONTRACT --> APP
    APP --> UNIT
```

### 主项目测试

- UI 域规则、错误映射、请求世代、路由和 Facade 替身下的状态转换。
- Widget 的加载、已有数据刷新、空、失败、取消、离线投影、待激活/损坏/回滚状态和
  明暗/窄宽/键鼠触摸语义。
- 主项目不创建 Runtime Store、协议 DTO、wire client、平台桥接或 `host.*` 测试替身。

### Runtime 自动化与契约测试

- TypeScript 类型检查、调度优先级、公平性、取消、deadline、插件清单/ESM、ZIP 校验、
  安装事务、冷激活、回滚、`ctx.http`、Cookie、资源流、背压、Range 和恢复。
- Runtime Store 的迁移、事务、缓存/下载策略、原子文件提交、`.part` 恢复和数据损坏。
- Runtime Facade 的强类型调用、错误投影、资源对象、自动启动和“零主项目注入”断言。
- shared schema/fixture 的 envelope、版本协商、错误码、Unicode、64 位数值、
  `ResourceHandle` 和插件清单边界。Runtime CI 定义生成、兼容检查和破坏性变更门禁。

### 当前 M1.2 已执行证据（不替代完整验收）

`mg_read_runtime` 当前 Windows x64 自动化已运行 Node Core 单测和实际 Flutter↔Node
集成测试：固定 Node child、stdout ready、loopback HTTP readiness、WS hello/ping、并发
Facade 调用共享一个 child、受控 shutdown，以及与共享 fixture 的版本一致性。Android/Javet
和任何移动端测试、macOS 运行/签名、最终应用包、Runtime Store、插件、资源 HTTP 和完整
故障矩阵均未执行。主项目不得以此为由新增 wire client 或跳过未来 Runtime 平台验收。

### 集成、故障与平台验收

Runtime 集成测试必须覆盖启动前失败、非法/重复 ready、readiness/hello 不兼容、内部
断线、deadline/取消竞争、snapshot、HTTP 200/206/304/410/416、慢消费者、大文件、
本地 ZIP 导入、安装中崩溃、Runtime Store 事务前后崩溃、下载恢复、磁盘满、插件缺失
离线投影，以及明确断言没有数据库/文件/Cookie/平台 callback 从主项目注入。

| 平台 | Runtime 必须验证 |
| --- | --- |
| Android arm64 | Javet Node 模式、专用线程、ESM、内部 HTTP/WS、Range、Runtime Store、前后台、强杀恢复、关闭、零注入 |
| Android x86_64 | 模拟器/CI 的同协议快速冒烟，不替代 arm64 真机 |
| Windows x64 | 包内 Node、隐藏启动、loopback、独立 Runtime 数据根、异常退出、安装升级 |
| macOS arm64 | 签名包内 Node、loopback、Hardened Runtime、公证产物启动、独立 Runtime 数据根 |
| macOS x64 | 独立 x64 包同等冒烟；不以 Rosetta 结果代替原生 x64 包验证 |

所有外部源站测试使用本地可控 fixture server，不依赖真实网站或真实凭据。

## 验收证据边界

交付报告必须分别说明文档/静态检查、自动化测试、主项目真实 UI 运行、Runtime 三平台
运行/安装、Android 真机原生行为和发布验收。任一层通过都不能替代另一层；未执行的层
必须明确写“未执行”和原因。

M0 文档阶段只执行术语、链接、交叉引用和两仓库边界一致性检查，以及既有静态检查。
它不运行应用、构建、平台冒烟或真机验收，也不为文档阶段创建空测试资产。
