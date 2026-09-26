# 原生 HTTP 改造验收

日期：2026-09-27。当前架构见 [实现契约](IMPLEMENTATION_CONTRACT.md)。App `0.10.12+382`，原生宿主/SDK/参考来源 `0.3.0`。
旧 [v2 记录](V2_ACCEPTANCE.md) 不作为本次 HTTP 改造的通过证据。

## 自动化与真实进程

| 层次 | 当前证据 |
| --- | --- |
| Rust | 宿主 4、SDK 7、Alice 8 项通过。SDK 使用真实 TCP 验证两个内容请求并发、断开一个只取消对应上游；无 cancel RPC |
| 资源协议 | HEAD、206/416、If-Range、HLS 主/子清单、分片/密钥/初始化片段改写、背压与断连释放通过；跨新实例保留 payload、超过 4096 个描述不失效 |
| Facade | package 全套 58 项通过；覆盖 Node/native 并存、初始化端点归属、取消、管理生命周期、旧描述按当前端口重绑 |
| App 适配器 | 封面、网关、漫画、音频/视频数据源 64 项通过；下载前解析当前 URL，封面缓存保留原身份 |
| Windows DLL worker | 错误初始化 ABI、失败/abort 隔离、禁用来源不加载、版本升级回退、删除旧文件、卸载后目录移除通过 |
| Windows 实际 Alice | 搜索、详情、733 章目录、首中末正文、长章、封面；先取得封面描述、重启 worker、未重新获取详情直接加载封面通过 |
| 原生构建 | Windows x64、Android x64/arm64 宿主通过；参考插件 Windows x64/Android arm64 同包 |

上述 socket/HTTP 成功不表示已经在真实 MediaKit 后端显示、出声或拖动。当前 `adb devices` 无设备，没有本次 Android 私有 Service 实机结果或手机能耗测量。

## 复现

- Rust：三个 crate 分别执行 `cargo +1.97.1 test --locked --manifest-path <Cargo.toml>`。
- 构建：`tools/build_native_runtime.ps1 -Platform all`，再 `plugins/sources/aisishuwu-native/tools/build.ps1`。
- DLL fixture：使用固定 rustc 将 `tools/abi_fixture.rs` 编译为 cdylib；运行 `tools/acceptance.py --host <exe> --plugin <mgplugin> --abi-fixture <dll> --output <json>`。
- Facade：在 `packages/mgread_plugin_runtime` 执行 `flutter test --no-pub`；目标原生测试为 native_supervisor、native_resource_routing、hybrid_runtime。
- 真实来源：根目录设置 `MGREAD_NATIVE_FACADE_ACCEPTANCE=1`，执行 `flutter test --no-pub --dart-define=MGREAD_NATIVE_RUNTIME=true plugins/sources/aisishuwu-native/test/windows_facade_test.dart`。不设置开关会跳过。
- Node：固定仓库 Node 26.10.0，build/typecheck、资源相关 8 项测试、check:no-native-addons 通过。

忽略目录证据：`artifacts/native-runtime/http-*-tests*.log`、`http-facade-suite.log`、`http-worker-acceptance.json`、
`http-real-facade-final.log` 与 `plugins/sources/aisishuwu-native/artifacts/native-runtime/windows-facade-report.json`。

## 尚待平台验收

- 默认双引擎 Windows App 与 Android APK 的冷启动、启停/卸载/更新、主进程播放器访问私有 Service 插件端口。
- 真实图片显示、音频播放与拖动、MP4 拖动、HLS 主/子清单/分片/密钥/初始化片段；重启中断后按原进度恢复。
- 代理切换后的真实媒体行为，长时间空闲/播放的内存和能耗。按同设备、相同流和缓存条件采样，不能从 HTTP 或 ABI 类型推断更快/更省电。

目标生产 Dart analyze 已通过。根 Final 检查被既有 `comic_reader_chrome.dart` 1172 非空行（上限 1000）挡住；
本次相关文件另行格式化、analyze 和直接测试。Facade package 的 test 目录 analyze 另有既有 desktop_runtime_proxy_test.dart 未使用 dart:io 导入告警，生产 lib 无问题。

最终来源包 SHA-256：`87acb01e60a570324b517b0c82160c96b2e90e42c9e7a43ac856a9f29b79ece3`。
最终 worker 记录为 `artifacts/native-runtime/http-worker-acceptance-final.json`，最终原生 Facade 直接测试 10 项通过。
Windows App 调试构建首轮失败，进一步构建诊断已按用户要求中止；本轮未执行 Android APK 构建。
文档检查仍有 README.md:22 四个既有缺失锚点。用户要求立即提交并停止检查，以上未完成验收不记为通过。
