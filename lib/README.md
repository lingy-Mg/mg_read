# MgRead 主应用源码结构

`lib/` 按已接受架构的依赖方向组织：

```text
app -> feature presentation -> feature application -> feature domain
                                      |
                                      v
                                 feature data -> core

reader data -> package:novel_reader_ui/novel_reader_ui.dart
```

- `app/`：唯一组合根、主题、路由和生命周期入口；可见文案在页面或局部组件内就地定义。
- `core/`：与具体业务无关的 UI 错误映射、诊断投影和小型 UI 基础能力；不含 Runtime、持久化、文件或调度实现。
- `features/`：按产品能力划分的垂直切片；跨 feature 只能通过公开的 application/domain 端口交互。
- `shared/`：真正跨 feature 的展示组件和小型无业务工具。

不要创建全局 `models/`、`services/`、`repositories/` 或 `providers/` 杂物目录。每个新模块的放置、职责和测试入口见 [主应用模块地图](../docs/implementation/main-app-structure.md)。
