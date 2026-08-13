# 测试目录结构

测试与 `lib/` 的职责边界保持一致：

- `app/`：启动、组合根和路由测试。
- `core/`：错误、持久化、迁移、文件恢复、Runtime 协议适配、调度和诊断基础能力的单元/集成测试。
- `features/`：按 feature 镜像 application/domain/data/presentation 测试；Widget 测试仍与所属 feature 放在一起。
- `support/`：无业务测试辅助、受控 fake 和 fixture builders；不得放真实正文、凭据、Cookie 或生产数据库内容。

每个新实现模块必须同步在对应路径增加受影响层级的测试。
