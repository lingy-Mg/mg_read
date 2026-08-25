# 源码文件规模治理

手写源码以非空物理行计数（空行不计，注释计入）。文件达到或超过 700 行后，只要本次任务修改该文件，实施者必须在同一任务中主动设计并开始按职责拆分；可安全完成的拆分必须完成，不能只记录、建 TODO 或把治理留给后续任务。达到 1000 行前必须拆分。只有可复核的性能、生命周期或语言可见性约束能临时阻止拆分，且必须在代码评审中说明原因、当前保留边界和后续拆分入口。

不要用 `part1`、`utils`、`helpers` 或仅移动代码来规避门禁。提取出的文件必须有单一、可命名的职责：公开门面只编排；持久化拆 repository/codec/worker；页面拆状态接线与 feature-private sections；Runtime 拆 transport、dispatch、lifecycle 和 capability adapter；测试按行为场景拆分。跨两个以上 feature 复用时才进入 `shared/`。

每个新建或按职责重构的 Dart library 文件在第一段使用以下结构；说明必须匹配该文件实际内容：

```dart
/// 书籍详情页面。
///
/// 职责：
/// - 展示书籍基本信息。
/// - 处理阅读、收藏、目录等操作。
///
/// 注意：
/// - 不要在 build() 中执行网络或磁盘 IO。
/// - 数据加载统一交给 BookDetailController。
///
/// TODO:
/// - 增加详情缓存。
/// - 增加 Hero 动画。
library;
```

没有已知待办时使用 `/// - 无。`。`library;` 后才可出现 import；`part` 和生成文件不新增它。TS/JS 等语言使用同等的模块 JSDoc，不能伪造 Dart 语法。

公开入口、Facade、wire method、错误码、持久化格式和稳定 Key 不因结构治理而改变。Dart 优先使用显式内部类型和导入；`part` 只允许用于无法原子解除 library-private 依赖的短期迁移，不能作为长期的按行分片方案。

执行：

```powershell
pwsh -File tools/check_source_file_sizes.ps1
```

策略在 `tools/source_file_size_policy.json`。其中 `legacyBaseline` 是临时债务清单：条目不能增长；减少时同一变更必须下调计数；低于 1000 行时必须移除；最终必须为空。每个遗留条目必须在 `legacyRationale` 有可审查原因，且原因必须指出下一次的真实职责拆分边界；它不能成为新增文件或普通重构的豁免。脚本扫描 Git 跟踪和未忽略的新源码，排除依赖、固定工具链、生成文件、构建产物、二进制和快照。
