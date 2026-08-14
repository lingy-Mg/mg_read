# 11 主应用持久化独立验收

持久化测试位于 `test/core/persistence/`，使用 `PersistenceTestkit` 创建临时数据根。测试不得依赖 Widget、页面、Node/Javet、网络、真实书源或真实用户目录。

首个交付至少覆盖：CRUD、重开持久化、完整 scope 隔离、revision CAS、损坏 JSON、未来版本只读保护、未知字段与 null/缺失语义、逐版本升级、批处理原子性、后台 executor 与关闭边界。平台验收分开报告：Windows 自动化通过不代表 Android 真机或 macOS 实际运行通过。

`test/core/settings/` 在同一临时数据根原则下追加 settings adapter 的真实 SQLite 验收：按注册
ID 单查询批读、分组合流/flush/close、重开、future/corruption 隔离、CAS 冲突重载合并、
JSON 配额与后台 codec worker。Fake Store 负责可控时间窗和注入失败/重试；它不能替代真实
SQLite adapter 结果。
