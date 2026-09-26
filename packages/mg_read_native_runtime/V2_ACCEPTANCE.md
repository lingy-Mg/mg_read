# 原生 v2 验收记录

日期：2026-09-26。对应 [实现契约](IMPLEMENTATION_CONTRACT.md)；本记录只描述本次代码的证据，
不复用历史 v1 的设备或播放器结果。App 版本为 `0.10.11+381`，宿主/SDK/参考来源版本为 `0.2.0`。

## 已完成

| 层次 | 结果 | 覆盖边界 |
| --- | --- | --- |
| Rust 单元及协议测试 | 宿主 6、SDK 6、Alice 8，通过 | 缓存隔离、取消、初始化/关闭；真实本地 HTTP 的 HEAD、206/416、If-Range、HLS 改写、密钥/初始化片段、背压、断连释放和活动期限 |
| Dart Facade | `mgread_plugin_runtime` 全套 55 项通过，相关文件 analyze 无问题 | Node/native 路由、端点身份、重启后旧 URL 拒绝、取消、管理失败后重启；含现有 Node 进程测试 |
| Flutter 漫画适配器 | 两个直接测试文件共 31 项通过，相关文件 analyze 无问题 | 非持久资源断连、404/410 后重新取章且至多重试一次；持久资源不盲目刷新 |
| Node 资源回归 | 8 项通过，使用仓库 Node 26.10.0 | 既有 HLS 回环、预热与流式资源路径；未修改 Node 引擎 |
| Windows 真实 DLL worker | `tools/acceptance.py` 通过 | 系统模块列表确认禁用/导入不加载 DLL；错误 ABI、init 失败/崩溃隔离、归档恢复、更新旧目录回收、重启后卸载文件 |
| Windows 实际 Alice Facade | `windows_facade_test.dart` 通过 | 搜索、详情、733 章目录、首中末正文、67,619 字节长章、49,309 字节封面；禁用/启用、清缓存、代理切换、崩溃后离线缓存恢复和导入导出卸载 |
| 编译与打包 | Windows x64、Android arm64/x64 宿主；Windows/Android 调试 App 构建通过 | 默认双引擎 APK；合并 Manifest 保留私有 Service 与本地明文策略。Alice 来源包含 Windows x64 与 Android arm64 二进制 |

来源包：`plugins/sources/aisishuwu-native/dist/aisishuwu-native-0.2.0.mgplugin`。
SHA-256：`a990296bd9503cec08b9ed2e878d2d9c5a8c6456c836ecf4b3c08d7a2f4fd5b4`。
真实 worker 验收与 Facade 导出比对均使用该包。构建产物、完整日志及私有测试数据留在忽略目录，不纳入 Git。

复现入口（在仓库根目录，原生构建使用固定 Rust 1.97.1）：

```powershell
cargo +1.97.1 test --locked --manifest-path packages/mg_read_native_runtime/Cargo.toml
cargo +1.97.1 test --locked --manifest-path packages/mg_read_native_runtime/sdk/Cargo.toml
cargo +1.97.1 test --locked --manifest-path plugins/sources/aisishuwu-native/Cargo.toml
./tools/build_native_runtime.ps1 -Platform all
./plugins/sources/aisishuwu-native/tools/build.ps1
```

Facade 全套测试在 `packages/mgread_plugin_runtime` 执行 `flutter test --no-pub`。
实际 Windows 来源测试必须在根目录设置 `$env:MGREAD_NATIVE_FACADE_ACCEPTANCE='1'`，再执行：

```powershell
flutter test --no-pub --dart-define=MGREAD_NATIVE_RUNTIME=true plugins/sources/aisishuwu-native/test/windows_facade_test.dart
```

未设置开关时该测试会跳过，不能记为实际来源通过。真实 worker fixture 入口与参数见 `tools/acceptance.py --help`。
主要证据为 `artifacts/native-runtime/v2-worker-acceptance.json`、`v2-facade-final-suite.log`、`v2-reader-tests.log`、
`sdk-v2-tests.log`、`v2-real-facade.log`、`v2-windows-build.log`、`v2-android-build.log`，
以及来源目录下的 `artifacts/native-runtime/windows-facade-report.json`。单次时延仅用于诊断，不构成桥接性能比较。

## 尚未通过实机验收的边界

本次没有可用 ADB 设备；未执行 Android 设备测试，也没有把 Windows HTTP/Facade 成功认定为 App 画面或实播成功。
Alice 是小说来源，不能用它证明原生音频、MP4 或 HLS 播放器已兼容。后续验收应使用 SDK 媒体 fixture 来源，
从真实 App 的统一 Facade 进入组件，而不是让播放器直接访问上游地址。

| 验收场景 | 方法及通过标准 |
| --- | --- |
| Windows / Android 冷启动 | 安装当前包，在来源禁用时检查 worker 模块/初始化事件；首次启用调用后才出现库与端口；Debug 和 Release 分别验证 |
| Android 私有 Service 回环 | 确认 `:mgread_native` PID 与 App 不同，App 的 HttpClient 和 MediaKit 均能访问服务端口；禁用/卸载后旧 PID 消失、旧端口拒绝连接；核查合并 Manifest 和设备明文网络日志 |
| 图片 | App 实际显示封面和漫画；重启 worker 后旧 URL 失效，非持久资源重新取章；错误来源/世代/端口不能被 Facade 接受 |
| 音频 / MP4 | 普通文件播放至末尾，前后拖动、暂停恢复、重启后重取；观察 Range/If-Range 与 206/416、Content-Range/Length 及内存，不以下载成功代替拖动成功 |
| HLS | 主清单、多码率子清单、音轨、分片、AES-128 密钥、fMP4 初始化片段及字节范围均实播；重定向相对路径正确，长时间播放和换集无令牌提前失效 |
| 上游代理 | 分别测试 HTTP(S)、SOCKS5/SOCKS5H 及关闭显式代理；切换时 worker 更新，后续上游流量进入新代理，App 到回环服务不绕代理 |
| 双引擎及卸载 | Node 来源持续可用；原生来源正在传输时更新/卸载，确认停止准入、旧进程退出与文件删除三个阶段；插件卡死也能由进程边界回收 |

## 收尾检查的现有阻塞

根 `run_flutter_checks.ps1 -Mode Final` 已执行，但在全仓规模检查处停止：
`packages/mg_read_reader_ui/lib/src/ui/comic/comic_reader_chrome.dart` 有 1172 非空行，超过 1000 上限。
因此不能称全仓 Final 通过；本次自有文件的 analyze、直接测试及构建单独完成。

`tools/check_documentation.ps1` 的既有失败是根 README 第 22 行四个目录锚点失效（快速开始、核心能力、数据源与扩展、开发入口）。
本次新文档链接通过。以上无关文件均保留原状。
