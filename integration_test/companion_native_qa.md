# 手机辅助 TV 验收

手机按正常流程打开视频，在播放器右上角选择“在电视上播放”，再选择局域网 TV。TV 模式自动开放接收，
不要求配对码或逐设备确认；首次实际起播成功后手机才暂停。断开手机保留 TV 播放，失败候选保留当前视频。
此通道不授予书架、来源插件或本地文件同步权限。TV 仍独立解析同一来源及版本，不传手机的媒体 URL 或凭据。

## 自动回归入口

- `test/features/tv_companion/`：直接 LAN 会话、旧 PSK 兼容、控制代次、接管、本地输入优先、目录与交接。
- `test/app/companion_tv_role_test.dart`：TV 启动开放接收，离开 TV 模式关闭，不创建同步配对。
- `test/features/media/application/companion_video_launcher_test.dart`：准备、接管和失败回滚。
- `packages/mg_read_video_player/test/`：通用播放器、候选首帧和复用后端。

## Windows 与 Android 原生流程

两端使用 `integration_test/companion_native_cast_qa_test.dart`，分别指定
`MGREAD_COMPANION_QA_ROLE=tv` 和 `phone`，测试包后缀均为 `MGREAD_APPLICATION_ID_SUFFIX=companionqa`。
Windows 角色采用真实 PairedSyncHost、CompanionController 和 MediaKit；手机采用正常播放目的页与播放器投屏按钮。
来源目录和身份使用隔离测试 fixture，媒体为真实 MP4 HTTP Range 流，不以此替代外部来源插件验收。

Windows 指定 `MGREAD_COMPANION_SAMPLE_PATH` 为本机 MP4 绝对路径，
`MGREAD_COMPANION_QA_REPORT_PATH` 为忽略目录下的 JSON 报告路径。
默认监听 `0.0.0.0:41079`，`MGREAD_COMPANION_QA_WINDOWS_ADDRESS` 默认 `192.168.50.200`。
手机用 `MGREAD_COMPANION_QA_HOST=192.168.50.200:41079` 访问协调服务，并通过实际手动连接弹窗输入 TV 端口。
MuMu 的 NAT 环境不保证转发 UDP 发现；手动地址流程不构成广播发现通过的证据。

手机依次断言本机真实首帧、按钮投屏、TV 首帧后手机暂停、遥控暂停/跳转/继续、下一集、
不可用选集失败后旧视频继续、断开后 TV 继续。测试截图和结构化状态由
`test_driver/companion_native_cast_qa.dart` 写入 `FLUTTER_TEST_OUTPUTS_DIR`。

`integration_test/companion_prepared_surface_qa_test.dart` 单独强制 Android 硬件解码与 `directSurface`：
挂载候选画面后准备首帧，接管同一后端并持续播放，再验证失败候选不破坏已接管会话。
该流程使用 `test_driver/companion_media_server.dart` 提供同一 MP4，启动时用 Dart define 指定 sample 路径。

Android 安装前必须用 `aapt2 dump badging` 核验真实包名为 `com.mgread.mg_read.companionqa`；
驱动使用已核验 APK 的 `--use-application-binary` 与 `--keep-app-running`，不覆盖或清理正式包。
Windows 构建完成后复制二进制输出到忽略的验收目录，避免后续构建覆盖运行中的接收端。

验收证据须区分 Windows/MuMu、真实网络会话、原生视频首帧与实体电视，不能将模拟后端或构建成功视作原生验收。

## 2026-11-04 验收记录

Windows 接收端与 MuMu BRA AL00（Android 12，ADB `127.0.0.1:16384`，x86_64）双端流程通过。
未创建配对或保存控制密钥；实际驱动手机正常播放页的投屏按钮和手动地址弹窗。
暂停、跳转到 12000 ms、继续、下一集均收到 applied；坏选集失败后仍播放 next，断开后仍有真实首帧且持续播放。
接收端结束前记录 next 的位置为 25375 ms。样本与元数据 fixture 不能替代外部来源或实体 TV 验收。

同一 MuMu 的 directSurface 候选首帧、接管后推进和失败候选保留播放通过，截图由 IntegrationTest binding 保存。
本轮实测修复了弹窗退出时过早释放输入控制器、原生后端 open 前静音失败、旧路由抢回新播放绑定、
以及继承系统代理导致局域网媒体首帧超时。局域网媒体在未显式指定代理时直接连接；显式用户代理仍保留。

本机证据保存在忽略目录 `.dart_tool/ai-checks/companion-qa/`，包括 `tv-final-report.json`、
`phone-complete-results/` 与 `surface-final-results/`。MuMu NAT 下采用手动地址；未宣称 UDP 广播发现或实体电视通过。

## 2026-11-04 实体 TV 补充验收

设备为 MiTV-ANSP0、Android 9、amlogic、armeabi-v7a，ADB 与 Wi-Fi 地址为 `192.168.50.102:5555`。
仅安装独立包 `com.mgread.mg_read.companiontvqa`，未覆盖正式应用或修改其数据。

实体 TV 角色通过 `MGREAD_COMPANION_QA_PHYSICAL=true` 运行；协调与媒体服务仍在 Windows，
由 TV 上报真实接收端口和播放器状态。该模式使用真实网络能力，不替换网卡或注入发现地址。
测试身份满足发现协议至少 16 字符的要求，配对记录及密钥写入会直接使验收失败。

`test_driver/companion_lan_probe.dart` 可在 Windows 运行，仅自动选择隔离验收接收端的真实 UDP 广播，
使用生产加密通道和命令类型连接，不提供预设 IP 或共享密钥。实测结果：

- Windows 连续收到来自 `192.168.50.102` 的发现广播，TV 接收状态为开启。
- 自动发现后直接获得控制，handoff 返回 started，实体 TV 真实首帧及持续播放成立。
- 暂停、12000 ms 跳转、继续、下一集、退出均返回 applied。
- 不可用选集返回 failed，仍播放 next；失败回退后实测位置 26166 ms，未丢失原播放。

MuMu 的真实网卡为 `10.0.2.15/24`，与电视的 `192.168.50.0/24` 隔着 NAT。
本轮手机实际打开了播放器右上角入口，但 40 秒内自动列表未出现实体 TV，未判为通过。
Windows 能接收同一广播，因此保留此环境限制与失败截图；不能据此宣称同 Wi-Fi 实体手机自动发现已验收。
本轮未完成“手机按钮到实体 TV”的完整交接；此前 Windows 接收端与 MuMu 的按钮交接结果单独保留。
用户随后要求不再追加测试，已停止设备驱动并归还 MuMu，没有用手动地址或伪造广播替代自动发现结果。

证据位于 `.dart_tool/ai-checks/companion-physical/`：`udp-probe.log`、`lan-probe-report.json`、
`lan-probe-next.log` 及 `phone-results/`。本轮只有验收代码与文档变化，不升级根应用版本。
定向 Dart 分析、格式和文档检查通过；全局源码规模检查被其他任务的
`packages/mg_read_node_runtime/src/desktop-runtime.ts` 收缩后未同步基线阻止，未修改该路径或基线。
