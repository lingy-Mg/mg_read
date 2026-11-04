# Runtime version matrix

本文件只记录 Runtime 跨平台必须共同升级的固定版本、平台选择和仍待真实验证的能力。实现与命令以当前
配置、公开类型、probe 和测试为准。

## 当前固定选择

| 项目 | 精确版本 |
| --- | --- |
| Android 默认 Javet | `com.caoccao.javet:javet-node-android:6.0.1`；Node `26.9.0` |
| Android 独立进程 | Node `24.21.0`；arm64-v8a/armeabi-v7a `libnode.so` 来自 fogtape/nodejs-mobile Android 24.21.0-0 |
| Windows bundled Node/npm | `26.10.0` / `11.19.1` |
| macOS bundled Node/npm | `26.10.0` / `11.19.1` |
| Windows/macOS Bun | `1.4.4`；官方 `@oven` 分发包，SHA-512 固定 |
| TypeScript | `5.9.3` |
| `@types/node` | `24.13.3` |
| protocol marker | `1.2` |

每个后端只接受自己的精确引擎版本（Node 或 Bun）；不得回退用户 PATH 或全局 Node。插件 `engines.node` 统一声明 `>=24`，
表示兼容 Node 24 及以上；这不改变宿主固定工具链。插件打包和安装不另设 Node 版本白名单。

## 平台与 ABI

| 平台 | 选择 | 证据边界 |
| --- | --- | --- |
| Android | 同包包含 Javet Node 26.9.0（arm64-v8a/x86_64）与 Node 24.21.0 私有进程（arm64-v8a/armeabi-v7a）；ARMv7 默认且仅支持 Node 私有进程，64 位默认 Javet，设置中选择并重启 App 生效；minSdk 24 | 新后端 `libnode.so` 是基于 Node.js 源码的移动端第三方构建，非 Node.js 官方 Android 二进制；模拟器集成验证与最终安装包验收分别记录 |
| Windows | bundled Node 26.10.0 / Bun 1.4.4，x64，设置选择并重启 App 生效 | Windows 测试不证明 Android、macOS 或最终安装包 |
| macOS | bundled Node 26.10.0 / Bun 1.4.4；当前产物为 arm64，设置选择并重启 App 生效 | arm64 验证执行、签名和启动；x64、hardened runtime 与公证待发布验证 |

Android Javet adapter 只在专用后台线程上创建一个 Node-mode `NodeRuntime`；进程后端只在私有 Service 的
专用线程调用 `node::Start`。构建选择一次只能启用一个后端，WebView 仍由主进程持有；不得引入 VM Pool、
Worker 或未经当前版本公开类型证明的 lifecycle API。

## 桌面 Bun 交付边界

产品行为、恢复矩阵和打包验收入口见 [桌面双运行时](desktop-dual-runtime.md)。

- 默认 Node；已安装来源、缓存和开发目录配置共用，不迁移、不复制来源。Windows 原生 Rust 引擎保持独立。
- Bun 启动禁用 dotenv 和自动依赖安装；以 `bunVersion` 校验二进制，Node 兼容版本如实报告。
- Bun 的代理、HTTP/2、资源流和取消走打包 Undici；开发构建继续使用仓库固定 Node/npm。
- 版本及下载摘要由 `tools/stage-bun-runtime.mjs` 固定；构建失败不能交付缺少 Bun 的正常桌面包。
- `npm run test:bun` 验证共享桌面用例；`npm run verify:staged-bun` 在独立工作目录验证打包 helper、
  来源调用和退出。两者加入 Windows/macOS CI。Windows 测试不代表 macOS 签名或实机验收。

## 升级单元

Javet artifact、各后端 Node、npm、协议兼容记录、锁文件、Facade fixture 和平台 probe 是
一个升级单元。候选升级必须先核对官方 release、minSdk、ABI 与 Node 版本，再同步配置、fixture 和测试；
不能用静态资料替代平台运行证据。

## 待验证项

- Android API 24+：两后端在真实 arm64 设备上的安装、插件数据面、取消、浏览器转发、代理、异常退出与安全关闭。
- Android 独立进程：已接线 Node 24.21.0；模拟器通过后仍需真实 arm64 设备及最终安装包验收。
- Android 包：Javet 仅用于 64 位；发布 ARMv7、ARMv8 与 ARM 混合包，并逐个验证 ELF 架构和运行时完整性。
- Windows 包：从最终 bundle 启动固定 Node，并验证 ready、取消和 shutdown。
- Node 26 的 SOCKS5 HTTPS IP 地址目标：固定 Undici 仍将 IP 当作 TLS SNI，Node 26 拒绝；Runtime 在开隧道前
  明确报错，域名目标仍可使用 SOCKS5。待上游支持无 SNI 的 IP 目标后再恢复。
- macOS x64：增加独立固定 Node 产物并验证执行、签名和启动。
- macOS 发布：验证 hardened runtime 与 notarization；开发签名不可代替这两项。
- 当前 Windows 自动化不能声明 Android Javet、macOS、最终 app bundle 或未运行的平台能力已完成。
