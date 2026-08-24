# ADR-0020：书源目录单次完整返回

- 状态：Accepted
- 日期：2026-08-24
- 决策者：MgRead 项目
- 局部替代：[ADR-0018](0018-recursive-discovery-document.md) 延续的目录分页规则

## 背景

预发布的 `source.getChapters.v1` 曾把来源目录分页暴露给宿主。真实书源可能在一个网页请求中
直接返回数百章，而 Runtime 单页上限会拒绝该结果；跨页预取、Reader 即时加载和 Content
Library 快照又因此形成重复请求与半目录竞态。当前尚未发布第三方兼容承诺，可以原地收敛 API 1。

## 决策

1. 保持方法名 `source.getChapters.v1` 和 Plugin API `1`，请求原地改为 `{id}`，结果改为
   `{items}`。删除 `cursor/pageSize/nextCursor/totalCount`，不提供探测、兼容层或双轨协议；旧分页
   请求或响应统一视为 `plugin_invalid_response`。
2. `items` 是当前完整、有序、章节 ID 唯一的目录，最多 5000 条，编码后的完整目录结果最多
   2 MiB。网站自身分页由书源内部追完并去重，不能暴露给宿主。
3. 搜索、发现、详情和正文继续使用各自现有的小响应预算。目录是 WS 控制面唯一的大 JSON 例外；
   desktop WS 单帧上限为 4 MiB、出站队列为 8 MiB，并支持 RFC 6455 的 64 位 payload length。
   Android 通过 Javet/MethodChannel 调用，但复用同一目录校验。
4. 主应用只在完整结果通过校验后调用一次 `syncNovelCatalog` 并切换活动快照。组合根共享同一个
   预取器；同书并发预取和 Reader 打开等待同一任务，预取失败后 Reader 可同步重试一次。
5. 详情页的“加载更多”和 Reader 的分片只扩大内存中的本地可见范围，不再次调用书源目录 API。

## 后果

- Runtime、Flutter Facade、官方模板、演示书源和所有内置真实书源必须一次性迁移并升版本。
- 5001 条、超 2 MiB、重复章节 ID、分页字段和超 4 MiB frame 都被稳定拒绝。
- 超过当前边界的作品需要未来的新版本目录/资源协议；不能静默提高为无界响应。
