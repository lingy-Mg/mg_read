# Runtime version matrix

本文件只记录 Runtime 跨平台必须共同升级的固定版本、平台选择和仍待真实验证的能力。实现与命令以当前
配置、公开类型、probe 和测试为准。

## 当前固定选择

| 项目 | 精确版本 |
| --- | --- |
| Android 默认 Javet | `com.caoccao.javet:javet-node-android:6.0.1`；Node `26.9.0` |
| Android 独立进程预留 | Node `24.21.0`；此处只记录兼容版本，不代表后端已接线 |
| Windows bundled Node/npm | `26.10.0` / `11.19.1` |
| macOS bundled Node/npm | `24.16.0` / `11.13.0` |
| TypeScript | `5.9.3` |
| `@types/node` | `24.13.3` |
| protocol marker | `1.0` |

每个后端只接受自己的精确 Node 版本；不得回退用户 PATH 或全局 Node。插件 `engines.node` 显式列出这四个
受支持版本，旧版 `>=24 <25` artifact 继续可读取。

## 平台与 ABI

| 平台 | 选择 | 证据边界 |
| --- | --- | --- |
| Android | 默认 Javet Node 26.9.0；独立进程 Node 24.21.0 预留；minSdk 24；arm64-v8a 生产、x86_64 emulator/CI | Javet AAR 只有 arm64-v8a、x86_64 native 库；仍需真实宿主 build 与生命周期证据 |
| Windows | bundled Node 26.10.0 x64 child process | Windows 测试不证明 Android、macOS 或最终安装包 |
| macOS | bundled Node 24.16.0；当前产物为 arm64 | arm64 验证执行、签名和启动；x64、hardened runtime 与公证待发布验证 |

Android adapter 只能在一个专用后台线程上创建一个 Node-mode `NodeRuntime`。事件循环、停止、低内存通知和
关闭必须在拥有线程上验证；不得引入 VM Pool、Worker 或未经当前版本公开类型证明的 lifecycle API。

## 升级单元

Javet artifact、各后端 Node、npm、协议兼容记录、锁文件、Facade fixture 和平台 probe 是
一个升级单元。候选升级必须先核对官方 release、minSdk、ABI 与 Node 版本，再同步配置、fixture 和测试；
不能用静态资料替代平台运行证据。

## 待验证项

- Android API 24+：单 NodeRuntime、`process.versions.node`、ESM parity、事件循环和安全关闭。
- Android 独立进程：Node 24.21.0 预留记录需由进程后端接线和设备运行验证。
- Android 包：真实解析 Javet AAR 的 arm64-v8a/x86_64 内容并排除未支持 ABI。
- Windows 包：从最终 bundle 启动固定 Node，并验证 ready、取消和 shutdown。
- Node 26 的 SOCKS5 HTTPS IP 地址目标：固定 Undici 仍将 IP 当作 TLS SNI，Node 26 拒绝；Runtime 在开隧道前
  明确报错，域名目标仍可使用 SOCKS5。待上游支持无 SNI 的 IP 目标后再恢复。
- macOS x64：增加独立固定 Node 产物并验证执行、签名和启动。
- macOS 发布：验证 hardened runtime 与 notarization；开发签名不可代替这两项。
- 当前 Windows 自动化不能声明 Android Javet、macOS、最终 app bundle 或未运行的平台能力已完成。
