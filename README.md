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

## 开发入口

仓库内 AI 与贡献者规范只有 [`AGENTS.md`](AGENTS.md) 一个入口；跨模块规范按需从
[`docs/development/README.md`](docs/development/README.md)路由到
[`docs/core.md`](docs/core.md)的单个章节。当前实现事实以公开类型、源码文件头和测试为准。
