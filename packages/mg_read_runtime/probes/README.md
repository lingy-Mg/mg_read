# Probe plan

当前 Windows x64 主机已执行 desktop Node Core、标准插件和 Flutter Facade 探针：固定 Node
子进程、`127.0.0.1:0`、stdout ready、HTTP readiness、WS hello/ping/list/search、并发 Facade
调用共享一个子进程、有序关闭，以及标准 package/lock 安装、冷激活与依赖复用。证据命令是
`npm test`、`npm run check:no-native-addons`、`npm run test:flutter-desktop` 与
`npm run benchmark:plugin`；具体范围见
[`docs/desktop-runtime-bridge.md`](../docs/desktop-runtime-bridge.md)。

这不是 Android/Javet、macOS package、完整 Runtime Store、资源流或全部业务协议验收。
移动端在本轮明确不测试。以下剩余探针仍全部由本仓库拥有；`mg_read` 不得实现替代 bridge
或提供 callback 让它们工作。

## Android Javet NodeRuntime gate

Run on each selected ABI, arm64-v8a and x86_64:

1. Resolve the exact 5.0.8 AAR and assert minSdk 24 packaging metadata.
2. Create exactly one NodeRuntime through the Node host on one dedicated
   background thread.
3. Verify process.versions.node equals 24.16.0, execute the same ESM fixture as
   desktop, and pump the event loop with await().
4. Bind a loopback ephemeral port, complete internal HTTP readiness and WS hello
   using the shared fixture without any database/path/Cookie/file/host callback
   injection from the main application, then shut down on the owning thread.
5. Repeat with pending Promise, timer, rejected Promise, and open connection
   cases. Record elapsed close time, uncaught/rejection behavior, leaks, native
   crash, and whether setStopping plus lowMemoryNotification changes the result.

Javet 5.0.8 has await(), lowMemoryNotification(), setStopping(), and close().
Do not assume setPurgeEventLoopBeforeClose() exists for this selected version.

## Desktop gate

Run the identical ESM, loopback, readiness, independent-startup and shutdown
fixture using the bundled official Node 24.16.0 binary:

- Windows x64;
- macOS arm64;
- macOS x64.

The macOS runs must also validate the signed and notarized application bundle;
they cannot be claimed from a Windows host.
