# Runtime version matrix

本文件只记录 Runtime 跨平台必须共同升级的固定版本、平台选择和仍待真实验证的能力。实现与命令以当前
配置、公开类型、probe 和测试为准。

## 当前固定选择

| 项目 | 精确版本 |
| --- | --- |
| Javet Android artifact | `com.caoccao.javet:javet-android:5.0.8` |
| Javet 携带的 Node | `24.16.0` |
| desktop bundled Node | `24.16.0` |
| bundled npm | `11.13.0` |
| TypeScript | `5.9.3` |
| `@types/node` | `24.13.3` |
| protocol marker | `1.0` |

Javet Node patch 与 desktop Node patch 必须完全一致；不得回退用户 PATH 或全局 Node。

## 平台与 ABI

| 平台 | 选择 | 证据边界 |
| --- | --- | --- |
| Android | Javet Node；minSdk 24；arm64-v8a 生产、x86_64 emulator/CI | 不支持 armeabi-v7a；仍需真实宿主 build 与生命周期证据 |
| Windows | bundled Node 24.16.0 x64 child process | Windows 测试不证明 Android、macOS 或最终安装包 |
| macOS | bundled Node 24.16.0；arm64/x64 分包 | 必须分别验证执行、签名、公证和启动 |

Android adapter 只能在一个专用后台线程上创建一个 Node-mode `NodeRuntime`。事件循环、停止、低内存通知和
关闭必须在拥有线程上验证；不得引入 VM Pool、Worker 或未经当前版本公开类型证明的 lifecycle API。

## 升级单元

Javet artifact、其 Node patch、desktop Node、npm、协议兼容记录、锁文件、Facade fixture 和三平台 probe 是
一个升级单元。候选升级必须先核对官方 release、minSdk、ABI 与 Node 版本，再同步配置、fixture 和测试；
不能用静态资料替代平台运行证据。

## 待验证项

- Android API 24+：单 NodeRuntime、`process.versions.node`、ESM parity、事件循环和安全关闭。
- Android 包：真实解析 Javet AAR 的 arm64-v8a/x86_64 内容并排除未支持 ABI。
- Windows 包：从最终 bundle 启动固定 Node，并验证 ready、取消和 shutdown。
- macOS：arm64/x64 分别执行，验证 codesign、hardened runtime、notarization 和启动。
- 当前 Windows 自动化不能声明 Android Javet、macOS、最终 app bundle 或未运行的平台能力已完成。
