# Windows 项目内 Node 工具链（强制）

## 唯一允许的 Windows Node 来源

Windows 的 Node、npm、Corepack 和相关测试/打包命令必须使用项目内随仓库保留的
精确工具链：

    tools/node-v24.16.0-win-x64/

关键可执行文件：

    tools/node-v24.16.0-win-x64/node.exe
    tools/node-v24.16.0-win-x64/npm.cmd
    tools/node-v24.16.0-win-x64/npx.cmd
    tools/node-v24.16.0-win-x64/corepack.cmd

当前固定版本为 Node 24.16.0 与 npm 11.13.0。它必须与
.node-version、package.json、package-lock.json、
protocol/compatibility.json 和 docs/runtime-version-matrix.md 保持一致。

## 打包要求

- Runtime 的 Windows 打包流程必须由本仓库的 `npm run stage:flutter-windows` 自动把整个
  `tools/node-v24.16.0-win-x64/` 目录与编译 `dist/` 复制到
  `packages/mgread_plugin_runtime/assets/runtime/windows-x64/`，作为 Runtime 自有发布物的一部分；
  不得把此职责留给 `mg_read` 主项目源码实现。
- Runtime 必须从该应用包内的固定 Node 路径启动；不得依赖用户 PATH、用户安装的
  Node/npm、系统 Node、nvm 或任何全局工具链。
- 打包前必须执行项目内 node.exe --version 与 npm.cmd --version 检查；版本不
  等于 Node 24.16.0、npm 11.13.0 时立即失败。
- 如果未来升级版本，先按版本矩阵的整体升级规则替换项目内工具链并更新所有版本
  记录；禁止只替换 Windows Node。

## 测试、构建与脚本要求

- Windows 上的 npm ci、类型检查、测试、构建、依赖审计和所有以后新增的 npm
  脚本都必须由项目内 npm.cmd 启动。
- 调用 npm 前必须把项目内 Node 目录放在 PATH 最前面，确保 npm 子脚本解析到同
  一份项目内 node.exe。
- 禁止裸调用全局 node、npm、npx、corepack，也禁止“项目内版本缺失时回退到
  全局版本”。找不到或版本不符必须报错。
- CI 与本地 Windows 验收都必须验证实际运行的可执行文件路径及版本，不能仅因
  系统全局 Node 恰好版本相同就视为通过。
- M1.2/M1.3 的 Flutter↔Node 通信与固定模板往返测试也由本仓库运行：先由项目内 `npm.cmd` build，再在
  `packages/mgread_plugin_runtime` 执行 `flutter pub get` 与 `flutter test`。Facade 在测试中
  启动的仍是本目录的精确 `node.exe`，不是 Flutter 主项目、PATH 或用户 Node。

PowerShell 示例：

~~~powershell
$nodeHome = Join-Path $PSScriptRoot 'tools\node-v24.16.0-win-x64'
$env:Path = "$nodeHome;$env:Path"
& (Join-Path $nodeHome 'npm.cmd') ci
& (Join-Path $nodeHome 'npm.cmd') run verify
& (Join-Path $nodeHome 'npm.cmd') run test:flutter-desktop
~~~

这里的 $PSScriptRoot 应指向仓库根目录；脚本位于子目录时先解析仓库根目录，
不能改用全局 Node。
