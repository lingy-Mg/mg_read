# 验证、打包与验收边界

在准备执行测试、打包、版本更新或交付结论时读取本文件。

## 最小验证矩阵

- 任务 Dart 文件：实际执行一次定向 `dart format <owned files>`，再用 `dart format --output=none --set-exit-if-changed <owned files>` 检查。
- 主应用发现 UI：运行最近的 widget/golden 测试与定向 `dart analyze`；视觉变化先更新指定 golden，再正常运行同一测试并查看图片。
- Runtime：必须把 `packages/mg_read_runtime/tools/node-v24.16.0-win-x64` 放到当前命令 PATH 最前面，再从 Runtime 根运行 `npm run verify:desktop`。不要回退到全局 Node。
- 爱丽丝、速读谷和官方模板：从各自目录运行 `npm run verify`；这同时 typecheck、测试并生成规范 artifact。
- 文档与源文件策略：运行 `pwsh -File tools/check_documentation.ps1`、`pwsh -File tools/check_source_file_sizes.ps1` 和 `git diff --check`。

若书源请求、选择器、分页或解析发生变化，再运行该书源的显式 live 测试。仅改变组件布局或图标语义时，离线投影测试即可覆盖书源输出；不要把此前 live 结果冒充本轮网络验证。

## 根应用规则

- 根 Flutter 生产代码或用户可见资源变化完成后，只执行一次 `pwsh -File tools/update_flutter_version.ps1 -ChangeType small`；并发任务已改变版本时，以执行当下值递增。
- 全仓 `flutter analyze` 应运行并单独报告。全仓格式只允许 `--output=none` 检查；脏工作区出现无关格式差异时，不得格式化、恢复或覆盖它们。
- 不使用 `git add -A`、`git commit -a`、reset、restore、checkout 或批量基线覆盖。

## 真实运行边界

Golden、widget、Runtime desktop、插件 live 和 Android Integration Test 是不同证据。Android 只在用户明确授权后使用已连接且 ready 的 `emulator-5556`（回退 `127.0.0.1:7555`），不得启动、控制或重置设备，不得用坐标、`adb input` 或系统截图取证。交付时明确列出未执行项。
