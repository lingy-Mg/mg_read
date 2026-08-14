# ADR-0100：应用拥有 Content Library 三层持久化

- 状态：Accepted
- 日期：2026-08-14
- 依赖：ADR-0011

## 决策

主应用以 `AppPersistence` 唯一打开/关闭 metadata、content 和受控文件对象层。`ContentLibrary` 是 feature 唯一可用的强类型门面；feature、reader 和 Runtime 均不接触 Drift、SQLite、动态 JSON 或绝对路径。元数据保持稳定 envelope；正文进入统一 `content.sqlite`，图片进入文件对象层。对象先提交、metadata CAS 后引用、旧对象异步回收，不假定跨库原子事务。

## 后果

目录使用 keyset 分页和 100–500 条批次写入；300,000 章为验收下限、350,000 为合成余量。统一正文表避免按书/章节分表；容量只能据代表样本和字节外推报告。移出书架不会删除共享内容或进度。
