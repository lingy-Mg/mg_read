# MgRead

MgRead 是以可安装数据源为在线内容入口的本地优先 Flutter 阅读应用。主应用负责页面、路由、主题、书架和
业务持久化；Runtime、阅读器和播放器以独立 package 维护。首发平台为 Android、Windows 和 macOS，
其中 Android 优先。

## 仓库组成

| 路径 | 用途 |
| --- | --- |
| `lib/` | Flutter 主应用 |
| `packages/mg_read_node_runtime/` | Node.js 数据源 Runtime Core |
| `packages/mgread_plugin_runtime/` | Flutter Runtime Facade 与平台宿主 |
| `packages/mg_read_reader_ui/` | 小说与漫画阅读器 |
| `packages/mg_read_audio_player/` | 音频播放器 |
| `packages/mg_read_video_player/` | 视频播放器 |
| `plugins/sources/` | 真实数据源项目；默认参考实现为 `aisishuwu/` |

## 本地运行

```powershell
flutter pub get
flutter run
```

各 package 的接入方式见其 README；数据源的名称、版本和能力以各自 `package.json.mgread` 为准。

## Windows 数据源自检

安装后的 Windows App 可在“我的 → 管理数据源”检测全部已启用来源，也可进入单个数据源详情执行检测。内置
引擎会经正式 Runtime 验证发现、搜索、详情、完整目录、首/中/末内容和资源代理，不依赖 Flutter 测试框架。

自动化工具也可直接启动正式可执行文件，测试过程和完整结果会直接输出到当前控制台：

```text
.\mg_read.exe --source-check=org.mgread.aisishuwu
.\mg_read.exe --source-check-all
```

CLI 会阻塞到完整链路测试结束后才退出；stdout 输出普通文本测试过程、完整解码结果和日志，stderr 输出错误。
进程退出码为：`0` 全部通过、`1` 已完成但包含失败、`2` 内部错误、`3` 需要人工交互、`4` 参数错误或平台不支持。

开发期插件直测使用纯 Node.js CLI，具体命令见
[`packages/mg_read_source_testkit/README.md`](packages/mg_read_source_testkit/README.md)。

## 开发入口

仓库内 AI 与贡献者规范只有 [`AGENTS.md`](AGENTS.md) 一个入口；跨模块规范按需从
[`docs/development/README.md`](docs/development/README.md)路由到
[`docs/core.md`](docs/core.md)的单个章节。当前实现事实以公开类型、源码文件头和测试为准。
