# 当前规划与证据快照

复核日期：2026-08-20。此页以 Git 跟踪的 `b0d5e5a` 为基线；复核时工作区存在大量并发未提交
代码、原生资源和测试改动，它们不计入“已完成”，也不由本次文档整理接管。

## 已有可复用基础

- 根 Flutter 应用已有 Riverpod 组合根、类型化路由、主题、主导航、书架/发现/搜索/插件状态/
  调试日志/个人页和阅读器宿主相关切片。
- 主应用已有 metadata persistence、全局 settings、Content Library 基础与 App 分段 TXT diagnostics；
  Runtime 复杂事件系统已删除，只保留 Debug 瞬时简单日志；
  具体能力和限制以各实现说明与测试为准。
- Runtime 在 Windows x64 源码/Flutter testkit 中已有固定 Node 24.16.0、ready/HTTP/WS、Job
  Object、标准插件安装/冷激活、插件列表和五个 `source.*.v1` 内容能力证据。
- monorepo 已含官方空白模板和一个真实书源；书源线上 smoke 与离线验证必须分开报告。
- 发现内容可启动 route-lifetime 的临时阅读会话；它不是正式入库、持久进度或下载闭环。

## 当前最高优先级缺口

1. **统一当前数据链路**：Runtime Facade 返回插件内容，主应用强类型 adapter 写入
   `ContentLibrary`；不得恢复 Runtime Store 作为书架/目录/进度权威，也不得复制 raw transport。
2. **正式内容闭环**：详情、目录、加入书架、正文/漫画对象、进度/书签和来源不可用恢复需按
   ADR-0011/ADR-0100 分包实现与验收。现有临时阅读会话不能替代。
3. **Runtime 平台门禁**：Android/Javet、最终 Windows 包和 macOS 两架构的生命周期、包内资产、
   关闭与发布证据仍需各自完成；任何单平台结果不能扩张声明。
4. **下载/缓存所有权决策**：网络传输属于 Runtime，应用业务元数据属于主应用；持久 checkpoint、
   文件提交和恢复的跨边界协议尚未由新的 Accepted ADR 完整固定，实施前先补决策与契约。
5. **文档持续校准**：每个交付包更新此页的 tracked evidence，不把未提交工作、计划或历史
   Runtime Store 设计写成当前架构。

## 里程碑解释

原 M0–M7 路线仍作为产品阶段词汇，详见
[产品路线图](../architecture/01-product-roadmap.md)，但不再用“编号到了哪里”替代证据。每个交付包
必须列出实际通过的静态、自动化、运行、平台/真机和发布层级；门禁未执行就保持未验证。

下一任务应从 [开发文档路由](../development/README.md)选择一个最窄包，不要同时尝试修完全部
缺口。
