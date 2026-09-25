# 爱丽丝 Rust/Wasm 参考来源

本目录拥有 Rust 路由、HTML 解析、身份和分页、Wasm 二进制构建、站点 fixture 与效果报告。原 JS 来源保持
独立，插件 ID 为 `org.mgread.aisishuwu.wasm`，与原来源可以同时安装。

- `rust/lib.rs` 只负责 ABI 内存；`parsing.rs` 只负责无 IO 的解析；`source.rs` 拥有能力与 continuation。
- 精确工具链见 rust-toolchain.toml；依赖见 Cargo.toml/Cargo.lock。只构建 wasm32-unknown-unknown。
- 固定 Node 执行 `npm.cmd verify`；修改路由/解析后执行 `npm.cmd run test:live`。Rust 单测用
  `cargo test --locked --lib`，宿主适配器单测位于 `packages/mg_read_source_wasm/test`。
- 不保存线上 HTML 或正文；证据只保留计数、耗时、哈希、状态和资源 MIME。基准测试使用中性 fixture。
- Windows 直接测试：根目录运行 `flutter test plugins/sources/aisishuwu-wasm/test/windows_facade_test.dart`。
  Android 使用根 `tools/run_android_integration_tests.ps1` 的 `android_wasm_source_test.dart` 目标。
- 修改已经安装过的二进制时递增来源版本，避免不可变 installed version 复用旧字节；不升级根 Flutter 版本。
