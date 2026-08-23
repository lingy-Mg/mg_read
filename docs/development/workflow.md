# 开发工作流与证据规则

## 开工

1. `git branch --show-current`、`git status --short`、任务相关 `git diff`。
2. 从 [开发路由](README.md)选择最窄文档集，完整阅读选中的必读文件。
3. 写清本次交付包、明确不做项、受影响所有者和验证层级。
4. 若与 Accepted ADR 冲突，停止实现并提出替代 ADR；不在代码里偷偷换边界。

## 实现

- 先公开契约/领域和纯逻辑，再 adapter、UI、原生与示例；只做到当前交付包。
- 保留工作区并发修改。不得 reset/restore、批量暂存或吸收不属于本任务的 hunk。
- 异步、取消、过期结果、关闭、错误、空态和资源释放与成功路径同时设计。
- 关键链路的事件/span/schema、隐私和性能门禁与实现同包完成；日志能力缺失时明确阻塞项，
  不用 `print` 临时代替。
- 凡新增或修改用户操作、异步加载、缓存、持久化、Runtime Facade 或后台任务，实施者都必须按
  [诊断接入规范](diagnostics-instrumentation.md)接入全局诊断，并在交付中报告对应的 canary 与
  span 终态证据；不得由 feature/Widget 自行向 VS Code、终端或文件输出日志。
- 页面、路由、跨 Feature 或 Runtime 消费的真实自动化测试只能写在 `integration_test/`，用
  `WidgetTester` Finder 和稳定 `Key` 驱动。禁止坐标点击、鼠标/键盘自动化、`adb input`、系统
  截图或 Computer Use。Android 截图测试先调用 `convertFlutterSurfaceToImage()` 并 pump 一帧，
  再由 `IntegrationTestWidgetsFlutterBinding.takeScreenshot` 请求，最后由
  `test_driver/android_integration_test.dart` 收集。
- Android 测试目标由用户在测试前启动并明确批准；当前仅允许 `127.0.0.1:7555` 与
  `emulator-5556`。Agent 只能验证批准目标已连接，不得创建、启动、选择、唤醒、关闭或重置，
  也不得改用其他设备。真实测试不得以 Windows App/设备代替。
- 当前 UI 交付范围只包含浅色模式：Integration Test、测试截图和小组件 Golden 必须显式固定
  浅色主题。深色/系统深色模式的完善、截图、Golden 和验收均延期；保留既有实现但不在浅色任务
  中顺手修改。

## 验证分层

| 层级 | 证明什么 | 不能证明什么 |
| --- | --- | --- |
| 格式/静态分析 | 语法、类型、lint、格式 | 交互和平台运行 |
| Golden（仅浅色小组件） | 很小且隔离组件的确定性浅色像素输出 | 页面、路由、完整交互、深色模式、真实 Runtime 或设备 |
| Android Integration Test（仅浅色） | 用户提供模拟器上的真实浅色 Flutter 交互、组件连接与故障边界 | 未运行的平台、深色模式、原生系统 UI 或发布包 |
| 平台/真机 | 对应平台原生行为 | 其他 ABI/主机或发布安装 |
| 发布验收 | 最终安装、升级、签名和包内资产 | 未覆盖的商店/渠道 |

根 Flutter 代码默认执行静态检查：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```

实际应用改动在用户提供并批准的 Android 测试目标已连接后，再执行（不会启动模拟器）：

```powershell
.\tools\run_android_integration_tests.ps1 -DeviceId emulator-5556 -All
```

小型孤立展示组件才可按需执行其 Golden 测试；不得把它列为实际流程验收。只改文档时执行
Markdown 相对链接检查、`git diff --check` 和任务文件 diff；不把未运行的业务测试写成通过。
Runtime、阅读器、模板和真实书源使用各自 `AGENTS.md`/README 规定的命令。

## 交付

重新检查 `git status` 和任务 diff，只列任务拥有文件。报告：完成内容、格式/静态、自动化、
真实运行、平台/真机、发布、日志/canary/性能证据，以及所有未执行项和原因。除非用户明确要求，
不要提交或 push。
