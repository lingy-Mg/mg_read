# MgRead Source Testkit

面向真实数据源插件的纯 Node.js 开发测试库。统一 Plugin API v1 契约、带 Runtime 默认桌面 UA 的临时宿主、
阅读链路、inline JSON 大小和资源抽样，不依赖 PowerShell、Flutter 或 Runtime 私有实现。

```js
import {
  assertStandardSourceContract,
  createSourceTestHarness,
  probeReachableResource,
  runReadingSourceFlow,
} from '@mgread/source-testkit';
```

来源专属页面结构和固定业务事实仍由各插件自己的 fixture/live test 负责。

Windows 开发环境直接使用仓库固定 Node。单源与全源命令分别为：

```text
packages\\mg_read_node_runtime\\tools\\node-v24.16.0-win-x64\\node.exe --use-env-proxy packages\\mg_read_source_testkit\\bin\\mgread-source-test.mjs --source aisishuwu
packages\\mg_read_node_runtime\\tools\\node-v24.16.0-win-x64\\node.exe --use-env-proxy packages\\mg_read_source_testkit\\bin\\mgread-source-test.mjs --all
```

CLI 默认先执行来源声明的 `build`，再从 `dist` 直接运行发现、搜索、详情、目录以及首/中/末内容抽样。`--all`
顺序执行全部来源并收集所有失败，不在首个失败处停止。可用 `--skip-build` 复用已有构建，用 `--report <path>`
指定紧凑 JSON 报告。
