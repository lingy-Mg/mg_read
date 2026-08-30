# MgRead Agent 最小入口

本文件只提供所有任务都需要的启动规则。跨模块规范集中在 [`docs/core.md`](docs/core.md)，但禁止
默认全文读取；先通过 [`docs/development/README.md`](docs/development/README.md)只定位一个相关章节。

## 开工顺序

1. 默认不在开工时例行检查当前分支、全仓 `git status` 或全仓 diff；只有为确认目标文件是否存在
   并发改动、划分修改归属、诊断 Git 问题或准备提交时，才做范围最小的必要检查。
2. 先读目标文件的文件头、最近的嵌套 `AGENTS.md`、直接相关测试和公开类型。
3. 只有触及跨文件或跨模块边界时，才从开发路由读取 `docs/core.md` 的一个章节。
4. 只有确实跨越第二个所有权边界时才增加第二个章节；不得为“了解项目”遍历整个 `docs/`、
   package README、历史提交或无关平台资料。

冲突时依次采用：用户当前要求 → `docs/core.md` → 最近的嵌套 `AGENTS.md` → 代码公开契约与测试。

## 工作区与范围

- 直接使用当前工作区，不创建 worktree、第二份检出或嵌套 Flutter App。
- 保留所有无关脏改动。禁止 `reset --hard`、restore/checkout 覆盖、`git add -A` 和
  `git commit -a`；不是本次 AI 修改的文件或代码块一律忽略，不修改、不暂存、不提交。
- 每次 AI 完成本次修改和必要验证后，必须按 Git 常规规范使用中文提交本次 AI 的改动。除非用户
  明确要求，不 push。
- 单文件职责、生命周期、IO、状态所有权和真实注意事项写在该文件头；目录级增量约束写在最近的
  `AGENTS.md`；只有稳定的跨模块边界进入核心规范。修改职责时同步维护文件头。
- 新增依赖前核对官方资料，精确固定版本，并确认维护状态、许可证、包体及首发平台影响。

## 版本与验证

- 根应用版本只由 `tools/update_flutter_version.ps1` 修改。仅根 Flutter 生产代码、用户可见资源或
  Android/Windows/macOS 发布配置变化时，在全部修改完成后执行一次 `-ChangeType small`；产品级
  大改使用 `large`。纯文档、测试、工具、package、模板或独立数据源插件改动不升级根版本。
- 每次代码修改执行 `pwsh -File tools/check_source_file_sizes.ps1`，再运行最近 `AGENTS.md` 指定的
  静态与自动化检查。根 Flutter 代码只格式化本次拥有的 Dart 文件；任务收尾时执行一次
  `flutter analyze` 和直接受影响的测试，不得无条件执行 `flutter test`。使用
  `tools/run_flutter_checks.ps1 -Mode Fast|Final -DartPath <owned files> -TestPath <direct tests>`；
  全仓格式检查和全量测试仅限明确要求的回归/发布，使用 `-Mode Full`。纯文档任务只执行
  `pwsh -File tools/check_documentation.ps1` 和 diff 检查。
- Runtime 的 Windows Node 命令使用仓库内固定 Node，不回退到全局 Node。
- 真实页面和跨层流程只在用户明确授权后使用 Android `integration_test`；仅可使用已连接且 ready
  的 `emulator-5556`，或回退到 `127.0.0.1:7555`。不得启动、控制或重置设备，也不得用桌面操作、
  坐标、`adb input` 或系统截图取证。
- 交付时分开报告静态检查、自动化测试、真实运行、平台/真机、发布和未执行项，不能互相替代。
