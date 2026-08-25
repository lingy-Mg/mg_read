# Architecture Decision Records

状态：权威索引。ADR 记录不能被普通实现或说明文档隐式改变的决策。

## 状态规则

- `Proposed`：讨论中，不约束实现。
- `Accepted`：已接受，所有实现和专题必须遵守。
- `Superseded`：结论已被新 ADR 取代，文件只保留历史原因。
- `Deprecated`：不再建议，但仍有兼容义务。

修改 Accepted 决策时：新增替代 ADR → 接受后标记旧 ADR → 同步专题、协议、测试和索引。
不允许直接改旧 ADR 的结论来抹去历史。

## 当前 Accepted

| ADR | 决策 |
| --- | --- |
| [ADR-0001](0001-single-node-vm.md) | 每个应用进程只运行一个 Node VM |
| [ADR-0002](0002-trusted-plugins.md) | 首版插件完全可信，不建立安全沙箱 |
| [ADR-0003](0003-node24-javet-platform-hosting.md) | Node 24；Android Javet，桌面固定官方 Node |
| [ADR-0004](0004-ws-http-transport.md) | Runtime 内部 WS 控制面与 HTTP 数据面 |
| [ADR-0007](0007-direct-distribution.md) | 首版 Android/Windows/macOS 站外分发 |
| [ADR-0011](0011-app-owned-versioned-persistence.md) | 主应用权威持久化与版本化 metadata records |
| [ADR-0015](0015-standard-node-plugin-projects.md) | 标准 Node 插件、npm lockfile 与依赖对象仓 |
| [ADR-0016](0016-segmented-text-diagnostics.md) | App 分段 TXT 日志与显式调试详情捕获；Runtime 部分已被 ADR-0024 取代 |
| [ADR-0018](0018-recursive-discovery-document.md) | 预发布递归发现组件树与集合定向分页 |
| [ADR-0019](0019-development-plugin-live-loading.md) | installed 冷激活、Windows development 即时加载与 Android 测试安装 |
| [ADR-0020](0020-complete-source-catalog.md) | 书源目录单次完整返回、5000 条/2 MiB 边界与 WS 大响应例外 |
| [ADR-0021](0021-foreground-lan-sync.md) | Windows/Android 前台点对点局域网同步与有限范围 |
| [ADR-0022](0022-lan-sync-qr-development-source-transfer.md) | 局域网二维码连接与 Windows Debug 开发书源显式传输 |
| [ADR-0023](0023-debug-runtime-http-inspector.md) | Debug Runtime HTTP 检查页与受控 LAN 例外 |
| [ADR-0024](0024-runtime-transient-simple-logging.md) | Runtime 仅保留瞬时简单日志，不持久化复杂事件 |
| [ADR-0100](0100-app-owned-content-library.md) | 应用拥有 Content Library 三层持久化 |

## Superseded / 历史

| ADR | 原决策 | 替代关系 |
| --- | --- | --- |
| [ADR-0005](0005-host-database-authority.md) | Flutter DB + `host.*` 反向提交 | 被 ADR-0008 取代；数据权威随后由 ADR-0011/0100 重新确立 |
| [ADR-0008](0008-standalone-plugin-runtime-boundary.md) | Runtime 独立且拥有全部业务数据 | 业务数据所有权被 ADR-0011/0100 取代；Runtime 平台/transport 边界继续由 ADR-0001/0003/0004 与当前契约约束 |
| [ADR-0009](0009-scoped-versioned-json-records.md) | Runtime Store 版本 JSON | 被 ADR-0011 的主应用 record store 模型取代 |
| [ADR-0010](0010-split-sqlite-content-store.md) | Runtime SQLite 元数据/正文分库 | 被 ADR-0011/0100 的主应用 Content Library 取代 |
| [ADR-0014](0014-tiered-diagnostics-storage.md) | SQLite 诊断索引与附件对象 | 被 ADR-0016 的 TXT-only 设计取代 |
| [ADR-0017](0017-versioned-plugin-content-contract.md) | 富内容投影、平铺发现分区与显式 null 语义 | 被 ADR-0018 取代；富内容/显式 null 规则在 ADR-0018 延续 |
| [ADR-0006](0006-cold-plugin-activation.md) | 所有插件一律只在应用进程冷启动激活 | 被 ADR-0019 取代；installed 冷激活保留，Windows Debug development 改为有序 Runtime 重载 |

当前没有 Proposed ADR。下载/缓存跨边界所有权、宿主提交协议或其他未决能力不能从历史 ADR
推导；实施前应新增明确决策。
