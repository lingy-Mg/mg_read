# 11 主应用持久化独立验收

持久化测试位于 `test/core/persistence/`，使用 `PersistenceTestkit` 创建临时数据根。测试不得依赖 Widget、页面、Node/Javet、网络、真实书源或真实用户目录。

首个交付至少覆盖：CRUD、重开持久化、完整 scope 隔离、revision CAS、损坏 JSON、未来版本只读保护、未知字段与 null/缺失语义、逐版本升级、批处理原子性、后台 executor 与关闭边界。平台验收分开报告：Windows 自动化通过不代表 Android 真机或 macOS 实际运行通过。
