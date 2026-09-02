# MgRead 数据源测试库增量规则

本 package 是纯 Node.js 数据源开发测试库，拥有公共契约断言、临时宿主、单源/全源驱动、标准阅读链路和
有界资源探测；不得依赖 Runtime 私有端口、数据库、Cookie、Flutter 或真实插件实现。

- 诊断返回阶段、稳定错误码、计数、HTTP 状态和 MIME 类型。
- 通用助手不得替代来源专属选择器、固定内容事实或 live 断言；调用方继续拥有这些判断。
- 资源探测只读取首个非空响应块并立即取消，不能把媒体完整读入内存或写入 fixture。
- CLI 只由 Node.js 驱动；外部调用不得依赖 PowerShell 包装脚本。子进程使用当前 Node 旁的 npm CLI 执行来源
  声明的构建脚本，确保仓库固定 Node 工具链继续生效。
- 使用仓库固定 Node 运行 `npm.cmd test`；本 package 不升级根 Flutter 版本。
