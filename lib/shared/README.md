# Shared 共享代码边界

`shared/` 只接收至少两个 feature 都需要、且不含业务规则的代码：

- `presentation/`：复用的无业务 UI 组件，必须使用 `app/app_theme.dart` 的语义主题。
- `utilities/`：纯小型工具，不访问数据库、文件、Runtime、Provider 容器或全局业务状态。

如果代码只服务一个 feature，必须留在该 feature 内；如果代码表达领域规则，必须留在拥有该规则的 `domain/`。
