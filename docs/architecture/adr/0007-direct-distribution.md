# ADR-0007：首版全平台站外分发

- 状态：Accepted
- 日期：2026-08-13
- 决策者：MgRead 项目

## 背景

MgRead 在线安装并执行可信 Node 插件脚本。应用商店对下载代码、改变应用功能、审核和内容政策有各自限制；直接把站外架构切换为 Google Play 或 Mac App Store 构建选项可能造成合规与产品行为冲突。

## 决策

- Android、Windows、macOS 首版全部站外分发。
- Android 发布签名的 arm64 安装包；Windows 发布 x64 安装包；macOS 分别发布 arm64/x64 包。
- macOS 使用 Developer ID、Hardened Runtime 和 Apple 公证/Stapling 流程。
- 包内 Node/Runtime 由应用发布流程更新，插件由唯一官方仓库或用户本地 ZIP 更新；两条更新链路不可互相覆盖。
- Google Play 和 Mac App Store 不属于首版分发目标。
- 改用任何应用商店必须新增 ADR，重新审查在线脚本、插件更新、内容、隐私、签名信任和审核政策。

## 后果

正面：

- 首版插件模型无需在实现前假设商店允许在线脚本行为。
- Node/Javet、Runtime 和插件生态可按项目版本矩阵整体发布。
- macOS 仍通过 Developer ID 和公证提供 Gatekeeper 可验证的应用发行链。

代价与风险：

- 项目自行承担下载站、更新提示、带宽、安装说明、证书、撤销和用户信任。
- Android 用户需允许站外安装；Windows 可能受 SmartScreen；macOS 必须持续维护签名和公证。
- 没有商店自动更新、分发分析或渠道审核保障。
- 未来进入商店可能需要改变插件能力或仓库治理，不能保证零迁移。

## 被拒绝的方案

- **首版同时发布商店和站外版**：在核心协议尚未完成时扩大政策、构建和行为矩阵。
- **把商店渠道视为相同二进制的上传动作**：忽略在线代码与内容规则。
- **macOS 未公证直接下载**：用户安装体验和 Gatekeeper 信任不可接受。
- **运行时在线替换包内 Node**：绕过平台签名闭包并破坏版本一致性。

## 变更条件

提出商店分发 ADR 时必须引用当时最新官方政策，并提供：插件代码审查/签名/撤销模型、仓库治理、应用功能边界、隐私披露、现有用户迁移、渠道差异测试和回滚计划。历史政策链接不能替代提交时复核。

## ADR-0008 职责澄清

平台分发结论保持 Accepted。Runtime 的 Node/Javet、平台 Adapter、Runtime Store 迁移、
签名闭包和平台探针由 `mg_read_runtime` 交付；`mg_read` 只集成其已发布产物并验收 UI，
不在主项目源码中实现 Runtime 打包或平台生命周期。

参考：[Apple 直接分发](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/)、[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)、[Google Play 动态代码政策](https://support.google.com/googleplay/android-developer/answer/16559646?hl=en)。
