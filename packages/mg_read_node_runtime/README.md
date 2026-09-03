# mg_read_node_runtime

MgRead 的 Node.js 插件 Runtime Core。它拥有固定 Node.js 执行环境、插件安装与调用和内部传输；同级
Flutter package `mgread_plugin_runtime` 拥有公开 Facade、Supervisor 与平台宿主。

## 组成

| 路径 | 用途 |
| --- | --- |
| `src/` | Node.js Runtime Core |
| `protocol/` | 内部协议 fixture |
| `probes/` | 平台与依赖探针 |
| `docs/runtime-version-matrix.md` | 当前固定版本、平台支持和待验证项 |

Flutter 使用方从同级 [`mgread_plugin_runtime`](../mgread_plugin_runtime/README.md) 接入。数据源项目格式和
artifact 以根核心规范、公开类型和测试为准。

开发和 AI 规则只在 [AGENTS.md](AGENTS.md) 维护。
