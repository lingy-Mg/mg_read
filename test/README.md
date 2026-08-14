# 测试目录结构

测试与 `lib/` 的职责边界保持一致：

- `app/`：启动、组合根和路由测试。
- `core/`：UI 错误映射、脱敏诊断投影和其他不承担 Runtime 职责的纯逻辑测试。
- `features/`：按 feature 镜像 application/domain/presentation 测试；只用强类型 Runtime
  Facade 替身验证状态转换，Widget 测试仍与所属 feature 放在一起。
- `support/`：无业务测试辅助、受控 fake 和 fixture builders；不得放真实正文、凭据、Cookie 或生产数据库内容。

本仓库不得创建 Runtime Store、数据库迁移、文件恢复、wire client、调度或平台 Runtime
测试。它们位于 `mg_read_runtime`，并按
[Runtime Store 独立验收规范](../docs/architecture/11-runtime-store-acceptance.md) 在临时数据根
中单独执行，不依赖本主应用、Node、网络或真实用户数据。

每个新实现模块必须同步在对应路径增加受影响层级的测试。
