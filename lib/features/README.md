# Feature 垂直切片边界

普通 feature 按 `presentation/`、`application/`、`domain/`、`data/` 四层展开：

- `presentation/`：Widget、不可变 view state 的渲染和用户意图转发；不直接访问数据库、文件、Runtime 或网络。
- `application/`：用例编排、取消、请求世代、事务边界和状态控制器。
- `domain/`：稳定业务类型、规则和 Repository/服务端口；不依赖 Flutter、Drift 或传输实现。
- `data/`：端口实现、Drift 映射、协议 DTO 映射和外部插件公开 API 适配。

`reader/` 依照已接受架构只含 `application/`、`data/`、`presentation/`，并且只能导入 `package:novel_reader_ui/novel_reader_ui.dart` 的公开 API。

Feature 之间不能深层导入对方 `data/` 或 `presentation/`。需要协作时，由拥有方在 `domain/` 或 `application/` 暴露窄端口。
