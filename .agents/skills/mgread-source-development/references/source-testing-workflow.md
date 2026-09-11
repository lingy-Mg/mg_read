# 自动检测与正式验收

## 两层入口

1. 开发阶段使用 `packages/mg_read_source_testkit` 的纯 Node CLI，检查 build、公开导出、临时宿主和 live 内容链路。
2. 开发完成后使用 Windows Release App 正式 CLI，经生产
   `SourceContentGateway -> Runtime Facade -> Runtime -> 已启用插件` 验证真实宿主。

Node 层不依赖 Flutter、PowerShell 包装或 Runtime 私有端口；App 层不是 `flutter test` 或
`integration_test`。先读取 [content-validation-matrix.md](content-validation-matrix.md)选择内容类型的通过标准。

## Node 单源与全源

从仓库根目录直接使用当前平台对应的仓库固定 Node，不回退系统 Node；Windows 示例：

```text
packages\mg_read_node_runtime\tools\node-v24.16.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --source aisishuwu --report artifacts\source-tests\node-aisishuwu.json
```

开发循环默认单源。testkit、公共 Source 契约或跨来源共用代码变化时追加：

```text
packages\mg_read_node_runtime\tools\node-v24.16.0-win-x64\node.exe --use-env-proxy packages\mg_read_source_testkit\bin\mgread-source-test.mjs --all --report artifacts\source-tests\node-all.json
```

`--source` 接受来源目录、package 名或 pluginId。CLI 默认执行来源声明的 build，再从 `dist` 检查 metadata、
标准导出、`activate(ctx)`、发现与有限 target、动态搜索、详情、完整目录、首/中/末有界内容样本和登记资源。
`test/acceptance.json.searchQuery` 只作无法派生查询时的后备；不得用固定 `contentId` 绕过自动发现与搜索。
`--skip-build` 只用于已确认 dist 与源码一致的重复诊断。

小说要按图书策略选择可读章节并验证文本；漫画、音频、视频与封面要分资源组报告。当前 CLI 若只返回一个聚合
`resourceStatus`，用来源 live 测试补齐其余组，并明确标记 `notTested`，不能推断全组通过。

### 当前 CLI 的解释边界

- `--all` 会枚举带 `contentKinds` 的 fixture/demo；生产来源健康率与测试基础设施契约状态分开统计。
- CLI 会执行 build，但不会替调用方准备缺失的 `node_modules`；全源前先检查依赖，`127` 先归类环境问题并按
  lock 恢复，再进行有效复跑。
- 当前自动搜索只使用一个派生查询，标准链路选择搜索首项；`search_empty` 或选中错误条目时，用来源 live 测试
  按内容矩阵的有界查询和稳定 ID 规则复核，不能直接断言解析器损坏。
- 当前章节抽样不自动跳过锁定项，资源结果只给一个聚合状态；严格验证必须补齐可读章节和各适用资源组。
- 当前全源报告和 stdout 可能在任务末尾才出现；监控进程而不是猜进度。修改 testkit 时优先增加逐源进度或
  原子检查点，不能改变“遇错继续”和最终退出码。

因此当前 `--all` 是完整项目筛查入口，不单独构成内容矩阵的完整验收。CLI `passed` 但适用资源仍未验证时，
对外结论必须降级为部分验证。

testkit 自身变化还运行固定 Node 的直接测试：

```text
packages\mg_read_node_runtime\tools\node-v24.16.0-win-x64\node.exe --test packages\mg_read_source_testkit\test\*.test.mjs
```

Node CLI 退出码：`0` 全部通过、`1` 已完成且存在来源失败、`2` 参数或启动失败。全源模式必须继续到最后一个
来源并保留所有失败。

## Windows 正式 App CLI

App、Runtime 或 Facade 改动后先构建与交付一致的 Release：

```text
flutter build windows --release
build\windows\x64\runner\Release\mg_read.exe --source-check=org.mgread.aisishuwu --source-check-report=artifacts\source-tests\app-aisishuwu.json
build\windows\x64\runner\Release\mg_read.exe --source-check-all --source-check-report=artifacts\source-tests\app-all.json
```

Windows Release 是 GUI 子系统进程；自动化用 `Start-Process -WindowStyle Hidden -Wait -PassThru` 等待真实退出，
再读取报告和 `ExitCode`。单源始终执行；testkit、Runtime 公共边界、宿主或跨来源逻辑变化时追加全源。

App 引擎验证 Runtime 状态、发现、搜索、详情、目录、按类型内容样本和 Runtime 代理后的资源。退出码：`0`
通过、`1` 完成但有失败/取消、`2` 内部或报告错误、`3` 需要交互、`4` 参数错误或平台不支持。

## 判读与报告

先看 `status/totals`，再按 `pluginId -> stages` 定位首错：

- Node/App 同阶段失败：检查来源解析、网络或公共返回值，单源有界复现一次。
- Node 过、App 为 `invalid_format`：检查 Runtime 公开校验，不能以 Node 代替宿主。
- Node 过、App 在 `resource.*` 失败：检查 proxy 描述和 Runtime 数据面。
- WebView/人工交互受限：记录 Node 能力边界，以 App 的 `interactionRequired` 或实际结果验收。
- 单次 live 失败：保留首次报告，只有界复跑一次，不无限重试到绿。

测试框架验收还需：离线自测；小说、漫画、音频、视频各一健康代表；每类至少一故意失败 fixture；全源遇错后
仍完成且返回非零。最终分开报告离线、live、各资源组、Node、App CLI、Windows/Android、外部阻塞和未执行项。
