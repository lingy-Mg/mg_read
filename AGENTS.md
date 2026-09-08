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

## 工作区与修改归属

- 直接使用当前工作区，不创建 worktree、第二份检出或嵌套 Flutter App。
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
- Android 真实流程仅在用户明确授权后使用已连接且 ready 的 `emulator-5556`，或回退
  `127.0.0.1:7555`。测试需要而 MuMu 模拟器尚未启动时，允许自动启动 MuMu；若回退地址尚未连接，使用
  `C:\Program Files\Netease\MuMu Player 12\nx\_main\adb.exe` 主动执行一次 `kill-server`、
  `connect 127.0.0.1:7555` 和 `devices` 后再测试。不得重置设备，也不得用桌面输入、坐标或 `adb input`
  取证。
- 交付时分开报告静态检查、自动化测试、真实运行、平台/真机、发布和未执行项，不能互相替代。
