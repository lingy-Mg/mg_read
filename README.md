# MgRead

`MgRead` 是 `novel_reader_ui` 的主 Flutter 应用骨架。它负责应用级导航、书籍来源、用户状态、持久化和后续业务功能；阅读器插件只负责嵌入式阅读体验。

当前阶段只提供可运行的应用壳、主题、功能目录边界和阅读器接入点，尚未接入真实书源、数据库、账号或网络服务。

## 与阅读器插件的关系

开发时通过同级目录的本地依赖接入插件：

```text
Desktop/
  mg_read/                # 本项目：主应用
  mg_read_reader_ui/      # 阅读器 Flutter plugin
```

主应用只能通过 `package:novel_reader_ui/novel_reader_ui.dart` 使用插件的公开 API，不能深层导入插件的 `lib/src/` 实现。

## 目录

```text
lib/
  app/                    # 应用入口、主题、集中字符串
  core/                   # 将来的基础能力与跨功能抽象
  features/
    library/              # 书架与书籍入口
    reader/               # 阅读器数据适配和页面宿主
  shared/                 # 可复用的应用级 UI 与工具
```

`features/reader/application/reader_launch_request.dart` 和
`features/reader/presentation/reader_host_page.dart` 是已建立的插件接入边界。后续实现书源和状态存储后，构造 `ReaderLaunchRequest` 并推入 `ReaderHostPage` 即可进入 `TextReaderView`。

## 开始开发

```powershell
cd C:\Users\q3499\Desktop\mg_read
flutter pub get
flutter run
```

支持目标当前为 Android 和 Windows。提交前的默认检查见 [AGENTS.md](AGENTS.md)：

```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
```
