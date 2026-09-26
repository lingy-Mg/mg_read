# MgRead AI 唯一入口

本文件是仓库内 AI 任务的唯一启动规范；README 只面向使用者，不提供额外 AI 规则。跨模块规范集中在
[`docs/core.md`](docs/core.md)，但不得默认全文读取，先通过
[`docs/development/README.md`](docs/development/README.md)定位一个相关章节。

## 开工与停止条件

1. 先定位目标文件，读取文件头、最近的嵌套 `AGENTS.md`、直接测试和公开类型。
2. 只有真实跨文件或跨 package 边界时才读取一个核心章节；找到所有者、公开边界和验证入口后停止扩读。
3. 不例行读取 Memory、历史任务、全仓 Git 状态或 package 文档；只有当前任务明确依赖历史决策、并发归属或
   Git 诊断时，才做一次精确检索并打开直接命中的少量证据。
4. 文件清单和搜索优先使用 `git ls-files`、`rg --files`、`rg` 与目标行段；禁止无排除的递归目录扫描，默认
   排除 `node_modules`、`build`、`.dart_tool`、缓存和 artifact。命中后只展开当前决策所需内容。
5. 同类命令失败后先诊断失败类别，不原样重复；完整长日志写入忽略目录，只把有界摘要带回上下文。

冲突时依次采用：用户当前要求 → `docs/core.md` → 最近的嵌套 `AGENTS.md` → 代码公开契约与测试。

## 插件系统任务入口

- Windows 和 Android 的正常 App 同时交付 Node 与 Rust 原生宿主；已安装来源按各自引擎动态装载，
  不是为两类来源分别打包 App，也不是用原生来源替换 Node 来源。macOS 当前只有 Node 宿主。
  `MGREAD_NATIVE_RUNTIME=true` 仅用于原生独立性验收；Android 默认 Node 后端是 Javet，私有 Node
  进程是另一个构建选择。
- 主应用只经 `packages/mgread_plugin_runtime/` 的 `PluginRuntime` Facade 调用插件。该 package 按来源的
  `engine` 归属路由安装、管理、内容调用和传输；Node 与原生宿主各有私有进程、安装根和资源服务，
  来源 ID 在两套引擎之间必须唯一。宿主随 App 交付，来源 artifact 可在安装后导入。
- Node 来源是打包为单个 JS 的 `.mgplugin.js` 或 Node `.mgplugin` 归档，由
  `packages/mg_read_node_runtime/` 执行；原生来源是 `engine=native` 的 `.mgplugin` 归档，携带按目标 ABI
  预编译的 Windows DLL / Android SO，由 `packages/mg_read_native_runtime/` 装载。两种归档格式不能混用；
  共享的内容语义在 `packages/mg_read_source_api/`，原生 C ABI 在原生 Runtime 的 `abi/`。
- 后续涉及插件打包、加载或平台交付时，先选目标 package 的最近 `AGENTS.md`、公开入口和直接测试；
  跨边界再从 `docs/development/README.md` 定位 `docs/core.md` 的相关章节。并存路由的直接验证入口是
  `packages/mgread_plugin_runtime/test/hybrid_runtime_test.dart` 和 `integration_test/android_hybrid_source_test.dart`；
  Android 真机或模拟器验证再读取 `.agents/references/android-testing.md`。

## 工作区与修改归属

- 直接使用当前工作区，不创建 worktree、第二份检出或嵌套 Flutter App。
- 使用 Codex 创建本仓库的新任务时，必须选择已保存 `mg_read` 项目的 `local` 环境；禁止选择
  `worktree` 环境或调用任何 worktree 创建工具。用户说“创建新任务”、“使用另一模型”或“并行处理”不构成
  创建分支、worktree 或第二份检出的授权；只有用户明确要求为本仓库创建它们时才能执行。
- 只在确认目标文件存在并发修改、划分归属、诊断 Git 或准备提交时检查相关路径。保留所有无关脏改动；
  禁止 `reset --hard`、restore/checkout 覆盖、`git add -A` 和 `git commit -a`。
- 完成修改和必要验证后，按 Git 常规规范使用中文提交本次 AI 自有改动；除非用户明确要求，不 push。
- 文件职责、生命周期、IO、状态所有权和真实注意事项写在文件头；package 增量写最近 `AGENTS.md`；只有
  稳定的跨模块边界进入核心规范。新增依赖前核对官方资料并精确固定版本。

## 版本与验证

- 根应用版本只由 `tools/update_flutter_version.ps1` 修改。根 Flutter 生产代码、用户可见资源或发布配置变化
  完成后执行一次 `-ChangeType small`；产品级大改使用 `large`。文档、测试、工具、package、模板和独立
  数据源插件改动不升级根版本。
- 根 Flutter 代码只格式化本次拥有的 Dart 文件；编辑循环用
  `tools/run_flutter_checks.ps1 -Mode Fast`，任务收尾用一次 `-Mode Final` 和直接测试。`-Mode Full` 仅限
  明确的回归或发布。代码修改同时执行源码规模检查；纯文档运行 `tools/check_documentation.ps1`。
- Runtime 和数据源的 Windows Node 命令使用仓库固定 Node，不回退全局 Node。
- Android 只有任务确实需要 Android 平台验证时才读取
  [`.agents/references/android-testing.md`](.agents/references/android-testing.md)，普通开发任务不得加载该手册。
