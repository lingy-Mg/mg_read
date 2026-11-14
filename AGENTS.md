# MgRead AI 唯一入口

本文件是仓库内 AI 任务的唯一启动规范；README 只面向使用者，不提供额外 AI 规则。跨模块规范集中在
[`docs/core.md`](docs/core.md)，但不得默认全文读取，先通过
[`docs/development/README.md`](docs/development/README.md)定位一个相关章节。

## 开工与停止条件

1. 先定位目标文件，读取文件头、最近的嵌套 `AGENTS.md`、直接测试和公开类型。
2. 只有真实跨文件或跨 package 边界时才读取一个核心章节；找到所有者、公开边界和验证入口后停止扩读。
3. 不例行读取 Memory、历史任务、全仓 Git 状态或 package 文档；只有当前任务明确依赖历史决策、并发归属或
   Git 诊断时，才做一次精确检索并打开直接命中的少量证据。
4. 同类命令失败后先诊断失败类别，不原样重复；完整长日志写入忽略目录，只把有界摘要带回上下文。

冲突时依次采用：用户当前要求 → `docs/core.md` → 最近的嵌套 `AGENTS.md` → 代码公开契约与测试。

## 工作区与修改归属

- 直接使用当前工作区，不创建 worktree、第二份检出或嵌套 Flutter App。
- 使用 Codex 创建本仓库的新任务时，必须选择已保存 `mg_read` 项目的 `local` 环境；禁止选择
  `worktree` 环境或调用任何 worktree 创建工具。用户说“创建新任务”、“使用另一模型”或“并行处理”不构成
  创建分支、worktree 或第二份检出的授权；只有用户明确要求为本仓库创建它们时才能执行。
- 只在确认目标文件存在并发修改、划分归属、诊断 Git 或准备提交时检查相关路径。保留所有无关脏改动；
  禁止 `reset --hard`、restore/checkout 覆盖、`git add -A` 和 `git commit -a`。
- 完成修改和必要验证后，按 Git 常规规范使用中文提交本次 AI 自有改动；除非用户明确要求，不 push。
- 生命周期、IO、状态所有权等不明显的约定就近说明；package 增量写最近 `AGENTS.md`，稳定的跨模块边界
  写入核心规范。新增依赖前核对官方资料并精确固定版本。

## 版本与验证

- 根应用版本只由 `tools/update_flutter_version.ps1` 修改。根 Flutter 生产代码、用户可见资源或发布配置变化
  完成后执行一次 `-ChangeType small`；产品级大改使用 `large`。文档、测试、工具、package、模板和独立
  数据源插件改动不升级根版本。
- 日常只格式化、分析本次拥有的 Dart 文件，按改动风险选择直接相关测试；通过后不重复运行。
  可用 `tools/run_flutter_checks.ps1 -DartPath ... -TestPath ...`；`Fast` 与 `Final` 均只检查传入范围，
  只有显式选择 `-Mode Full` 才运行全仓分析与测试。小改动不要求全仓或整 package 验证。
- 测试优先覆盖真实故障、数据和关键交互；不为控件选型、文件行数、目录布局或实现写法新增全局扫描测试。
  文档修改按需核对链接与内容，不设强制文档检查和固定目录数量。
- Runtime 和数据源的 Windows Node 命令使用仓库固定 Node，不回退全局 Node。
- Android 只有任务确实需要 Android 平台验证时才读取
  [`.agents/references/android-testing.md`](.agents/references/android-testing.md)，普通开发任务不得加载该手册。
