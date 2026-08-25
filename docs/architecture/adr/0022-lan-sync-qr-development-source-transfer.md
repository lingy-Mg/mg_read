# ADR-0022：局域网二维码连接与开发书源传输

- 状态：Accepted
- 日期：2026-08-25
- 细化：[ADR-0019](0019-development-plugin-live-loading.md)、[ADR-0021](0021-foreground-lan-sync.md)

## 背景

UDP 发现和手动地址可完成局域网连接，但手机连接电脑时扫描二维码更直接。Windows Debug 又会
以 `development` 状态直读工作区书源；若同步只枚举 Runtime 保留的 installed 归档，这些正在
开发、且最需要在手机验证的书源无法进入同步清单。

## 决策

1. 发送端把协议版本、会话 token、私有 IPv4 和端口编码为 `mgread://lan-sync/v1` 二维码。二维码
   不包含六位确认码；扫码后双方仍必须显示并人工核对同一个六位码。
2. Android 接收端仅在用户明确打开扫码页时申请并使用相机。扫码不可用或被拒绝时继续保留 UDP
   发现和手动地址，不把相机变成同步前置条件。Windows 不承诺扫码输入。
3. 用户明确发起“发送数据”时，Windows Debug Runtime 可以把当前已加载的 development 标准
   Node 项目生成 Runtime 私有临时 `.mgplugin`。普通开发调用仍直接读取工作区，不因本决策改为
   先打包或安装。
4. 临时包只包含正式打包允许的 package/lock、`dist/assets/packages/tools` 和说明/许可文件，
   不包含 `src/test/node_modules`。归档仍服从 32 MiB 单包、32 项/512 MiB 单批、确定性 ZIP、路径
   和原生文件校验。
5. 为允许同一开发版本反复传到手机，Runtime 在临时包内把 package 与 lock 根版本一致改写为
   下一 patch 的 `devsync` 预发布版本。工作区文件不修改；已存在更高正式版本的接收端仍禁止降级。
6. 接收端只按标准 installed 流程校验、安装和冷激活临时包，不建立 Android development 路径，
   不复制 Windows 路径或开发状态。临时发送归档在 Runtime 关闭时清理。

## 诊断、隐私与失败

二维码原文、会话 token、IP、端口、相机画面、工作区路径、代码和归档字节不得进入诊断。现有
`lan.sync.session` owner span 只记录阶段、计数、字节、结果和稳定错误码。二维码格式错误、相机
不可用、开发项目不满足正式打包约束或归档超限均安全失败，并保留发现/手动连接或跳过不可传插件。

## 后果

- 手机可以扫码连接电脑，并继续依赖六位确认码防止扫错会话。
- 开发书源无需手工 pack/copy 即可经显式同步安装到手机，但手机端得到的是标准 installed 版本。
- `mobile_scanner` 只支持 Android/macOS/iOS/Web；当前产品实际接入 Android，Windows 保留非扫码
  接收路径。
