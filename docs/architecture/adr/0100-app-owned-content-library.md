# ADR-0100：应用拥有 Content Library 三层持久化

- 状态：Accepted
- 日期：2026-08-14
- 依赖：ADR-0011

## 决策

主应用以 `AppPersistence` 唯一打开/关闭 metadata、content 和受控文件对象层。`ContentLibrary` 是 feature 唯一可用的强类型门面；feature、reader 和 Runtime 均不接触 Drift、SQLite、动态 JSON 或绝对路径。元数据保持稳定 envelope；正文进入统一 `content.sqlite`，图片进入文件对象层。对象先提交、metadata CAS 后引用、旧对象异步回收，不假定跨库原子事务。

## 后果

目录使用 keyset 分页和 100–500 条批次写入；本交付只做功能验证，不包含容量或压力测试。统一正文表避免按书/章节分表。漫画文件按 LibraryItemId 分目录，移除漫画时删除其整个文件夹。
