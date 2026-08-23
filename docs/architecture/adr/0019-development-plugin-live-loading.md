# ADR-0019：安装插件冷激活与 Windows 开发插件即时加载

- 状态：Accepted
- 日期：2026-08-22
- 决策者：MgRead 项目
- 替代：[ADR-0006](0006-cold-plugin-activation.md)
- 细化：[ADR-0015](0015-standard-node-plugin-projects.md)

## 背景

不可变安装版本需要事务、回滚和稳定模块生命周期，因此不能覆盖或热换当前版本。但 Windows
开发期间若每次修改书源都先生成 `.mgplugin`、复制进 Flutter assets、安装并重启应用，会把开发
循环错误地绑定到发布运输流程。Android 又不能安全地直接读取 Windows 工作区，必须验证真实的
打包和安装路线。

## 决策

1. 插件明确分为两类：`installed` 是 Runtime 数据根内的不可变安装版本；`development` 是仅在
   Windows Debug 主机中直接读取的工作区标准 Node 项目。
2. installed 插件继续完整遵守安装事务、`pending/current/previous/failed`、下次 Runtime 冷启动
   激活和失败回滚。同一进程不覆盖、清除缓存或热换已安装模块。
3. Windows Debug 由 Runtime 平台适配器在仓库内解析 `plugins/sources`，以内部启动参数交给
   Runtime。主应用和公开 Facade 不接收、返回或保存插件路径。
4. development 插件直接使用工作区的 `package.json`、lockfile、`dist/`、资源和已有
   `node_modules`；不生成 `.mgplugin`，不复制到 Flutter assets，不写入安装版本树。开发者负责用
   `tsc --watch` 或来源自身的构建命令持续更新 `dist/`。
5. 每次 Facade 调用前，Windows Debug 适配器对 package/lock 与 `dist/assets/packages` 做有界
   指纹检查。发生变化时先停止并回收旧 Node Runtime/VM，再启动唯一的新 Runtime 并执行本次调用；
   不在同一 VM 中使用 query import、`require.cache` 清除或保留多代模块。
6. development 与 installed ID 相同时仅在当前 Debug 进程中由 development 投影覆盖；安装记录
   不变。开发投影标记为 `development`，不能通过安装插件的启停操作写持久 marker。
7. Windows Release 不携带工作区书源，也不把开发路径写入产物。插件必须经正式导入/安装能力进入
   installed 生命周期。
8. Android 测试在 Windows 用固定 Node 24 工具链验证并打包 `.mgplugin`，只通过受控测试脚本向
   已批准设备执行 ADB 文件传输。脚本把归档放入 Debug 应用私有 import inbox；Android Runtime
   在插件管理器冷初始化前调用正式 `PluginInstaller`，安装成功后删除 inbox 归档。Android 不扫描
   Windows 开发目录，也不把测试 inbox 暴露给主应用 UI。

## 安全与生命周期

- 任意时刻最多一个 Node Runtime/VM；开发重载必须串行，旧进程退出和 Job Object 清理完成后才能
  启动下一进程。
- 指纹最多 4096 个文件、32 MiB；导入 inbox 最多 32 个归档、单包 32 MiB。路径、代码内容和原始
  安装异常不进入默认诊断。
- Android 测试脚本仍只接受根开发契约批准的设备，不启动、唤醒、选择或控制模拟器，也不使用
  `adb input`。ADB 只承担测试归档传输和 Debug 应用私有 inbox 准备。

## 后果

- Windows 插件编辑在下一次来源调用时生效，开发循环不再依赖 pack/copy/install。
- Runtime Core 本身的修改仍需编译和暂存；本决策只取消开发书源的资产复制。
- Android 验证覆盖真实归档校验与不可变安装，不冒充 Windows 开发加载证据。
- 开发插件若启动 Timer、连接或其他长期资源，整颗开发 Runtime 重启会统一回收；已安装插件仍保留
  原冷激活和回滚保证。
