# 21 前台局域网同步

状态：已实现的权威架构专题；决策见 [ADR-0021](adr/0021-foreground-lan-sync.md) 与
[ADR-0022](adr/0022-lan-sync-qr-development-source-transfer.md)。

## 会话模型

同步是 Windows/Android 之间的前台、点对点会话。任一端可发送；双方都必须保持前台。UDP 用于
局域网发现，用户也可手动输入 IPv4 作为回退；发送端还显示版本化二维码，Android 接收端可扫码
取得同一会话的全部可用地址。地址枚举只保留 RFC1918 IPv4，并排除名称明显属于 WSL、Hyper-V、
Docker、虚拟机、VPN 或隧道的网卡，以及回环、链路本地和 CGNAT 地址。接收端对二维码中的地址
并发执行有界 TCP/协议握手，自动采用首个成功地址。配对后双方显示六位数字并比较，任何不一致
都终止会话。二维码不携带或替代确认码。传输是可信私有局域网明文，不提供云端、后台或加密承诺。

硬边界如下：

| 项目 | 上限 |
| --- | --- |
| 会话 | 10 分钟 |
| 握手 | 30 秒 |
| 控制帧 | 64 KiB |
| manifest | 1 MiB |
| 普通数据 chunk | 256 KiB |
| 插件归档 | 32 MiB |
| 单批 | 32 项或 512 MiB，先达到者结束 |

帧必须版本化、强类型并有长度边界；超限、截断、未知版本或顺序错误均为稳定失败，不以无限
缓冲或 JSON/Base64 绕过边界。

## 数据所有权与范围

主应用从 AppPersistence/Content Library 生成书架与阅读进度快照，并负责逐本冲突选择：智能合并、
采用发送端或保留本机。智能合并采用发送端展示信息，并仅在发送端进度更新时间较新时更新进度。
同步不包含离线正文、设置、书签或删除操作。快照落库仍服从
[ADR-0011](adr/0011-app-owned-versioned-persistence.md) 与 [ADR-0100](adr/0100-app-owned-content-library.md)。

插件仅支持“缺失安装”和“版本升级”场景。归档属于 Runtime 所有的数据，Runtime 通过 path-free
有界流提供；Flutter 不接收路径、不扫描 Runtime 数据根。npm 依赖按标准规则正常下载，归档不承担
离线依赖包分发。

Windows Debug development 书源只在用户显式开始发送时由 Runtime 临时打成标准归档。临时归档
使用单调的下一 patch `devsync` 预发布版本，因此同一工作区版本的后续修改仍可升级到手机；手机
仍按 installed 生命周期安装，不获得工作区路径或 development 加载模式。完整决策见
[ADR-0022](adr/0022-lan-sync-qr-development-source-transfer.md)。

## 平台与诊断

Android targetSdk 36 使用 `INTERNET`；targetSdk 37 的本地网络权限是未来兼容事项。同步的每个
App 用户操作使用单一 owner span 并遵守 ADR-0016；Runtime 只按 ADR-0024 输出瞬时简单日志。
两者都只允许阶段、计数、大小、耗时、稳定结果/错误码和脱敏版本投影。IP、比较码、token、书名、
作者、remote ID、归档字节、路径和原始错误永不进入日志。

二维码渲染精确固定 `qr_flutter 4.1.0`，为 BSD-3、纯 Flutter 且覆盖当前发布平台；Android 扫码
精确固定 `mobile_scanner 7.4.0`，同为 BSD-3，并使用包内 ML Kit，避免首次扫码依赖临时下载，
代价是 Android 包体约增加 3–10 MiB。该扫码包不支持 Windows，因此 Windows 接收端继续使用
发现和手动地址；相机声明为可选硬件，没有相机不影响应用安装和非扫码同步。

## 当前实现与验证

- Flutter 主应用实现 UDP 发现、手动 IPv4 回退、TCP 有界帧、六位码双端确认、导入预览和取消；
  “我的”页面只提供按需入口，不在后台自动启动。
- 发送端二维码包含同一会话最多 16 个经过筛选的候选地址；Android 接收端仅在用户打开扫码页时
  使用相机，并发握手后自动采用可达地址，扫码失败仍可发现或手动连接。
- Windows Debug development 书源可在显式同步时临时打包，并在接收端走标准安装与冷激活。
- Content Library 实现最多 100 条的元数据/进度快照、插件可用性阻断、revision stale 检测和
  单事务应用；Runtime Facade 实现 path-free 归档列表、计划、流式导出/整批导入、SHA-256 校验、
  SemVer 禁止降级和一次冷激活。
- 2026-08-25 已通过 `flutter analyze`、同步/Content Library/Profile/App 相关 Flutter 测试、
  Runtime Node 52 项测试、Runtime Flutter desktop 16 项测试与 no-native-addons 检查。
- Android Debug APK 与 Windows Release 已完成编译；Android Integration Test、Windows/Android
  双设备真实局域网互传和发布包验收仍未执行，不能由上述自动化证据替代。Windows Debug 编译
  曾因已运行应用锁定 Debug 可执行文件而失败，Release 独立输出随后通过。
