# mg_read_runtime

MgRead 独立插件 Runtime。它拥有固定 Node/Javet 执行环境、插件安装与调用、平台宿主、内部传输和
Flutter-facing Facade；主应用只消费版本化公开调用，不接触 Runtime 内部端口、路径或平台对象。

## 组成

| 路径 | 用途 |
| --- | --- |
| `src/` | Node Runtime Core |
| `packages/mgread_plugin_runtime/` | Flutter Facade 与平台宿主 |
| `protocol/` | 内部协议 fixture |
| `probes/` | 平台与依赖探针 |
| `docs/runtime-version-matrix.md` | 当前固定版本、平台支持和待验证项 |

Flutter 使用方从 [`mgread_plugin_runtime`](packages/mgread_plugin_runtime/README.md) 接入。数据源项目格式和
artifact 以根核心规范、公开类型和测试为准。

开发和 AI 规则只在 [AGENTS.md](AGENTS.md) 维护。
