# Feature 垂直切片边界

普通 feature 按 `presentation/`、`application/`、`domain/`、`data/` 四层展开：

- `presentation/`：Widget、不可变 view state 的渲染和用户意图转发；不直接访问 Runtime Store、文件、Runtime 内部协议或网络。
- `application/`：UI 用例编排、取消、请求世代和状态控制器；不管理 Runtime 生命周期或事务。
- `domain/`：稳定的 UI-facing 类型、规则和窄端口；不依赖 Flutter、Runtime wire schema 或传输实现。
- `data/`：Runtime Facade 与外部插件公开 API 的 UI 映射；不实现 Drift、文件、协议 DTO、Repository 或网络。

`reader/` 依照已接受架构只含 `application/`、`data/`、`presentation/`，并且只能导入 `package:novel_reader_ui/novel_reader_ui.dart` 的公开 API。

Feature 之间不能深层导入对方 `data/` 或 `presentation/`。需要协作时，由拥有方在 `domain/` 或 `application/` 暴露窄端口。
