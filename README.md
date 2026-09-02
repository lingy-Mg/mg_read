# MgRead

MgRead 是以可安装数据源为在线内容入口的本地优先 Flutter 阅读应用。主应用负责页面、路由、主题、书架和
业务持久化；Runtime、阅读器和播放器以独立 package 维护。首发平台为 Android、Windows 和 macOS，
其中 Android 优先。

## 仓库组成

| 路径 | 用途 |
| --- | --- |
| `lib/` | Flutter 主应用 |
| `packages/mg_read_runtime/` | 数据源 Runtime 与 Flutter Facade |
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

自动化工具也可直接启动正式可执行文件并读取 JSON 报告：

```powershell
.\mg_read.exe --source-check=org.mgread.aisishuwu --source-check-report=source-check.json
.\mg_read.exe --source-check-all --source-check-report=source-check-all.json
```

进程退出码为：`0` 全部通过、`1` 已完成但包含失败、`2` 内部错误或报告写入失败、`3` 需要人工交互、
`4` 参数错误或平台不支持。失败报告只包含插件标识、版本、阶段、稳定错误码、耗时和计数，不写入查询词、
标题、URL 或正文。

CLI 标准输出同时提供 JSONL 调试流：会实时输出启动和阶段状态，并在阶段完成后输出完整解码结果、URL、
标题、正文、资源请求头及异常堆栈。该输出仅用于显式 CLI 测试，不写入上述稳定报告或常规 App 诊断。

开发期插件直测使用纯 Node.js CLI，具体命令见
[`packages/mg_read_source_testkit/README.md`](packages/mg_read_source_testkit/README.md)。

## 开发入口

仓库内 AI 与贡献者规范只有 [`AGENTS.md`](AGENTS.md) 一个入口；跨模块规范按需从
[`docs/development/README.md`](docs/development/README.md)路由到
[`docs/core.md`](docs/core.md)的单个章节。当前实现事实以公开类型、源码文件头和测试为准。
