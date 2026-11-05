# 本地与 Actions 发布打包

本页记录发布入口、体积约束与验证边界。应用功能和运行时选择不因压缩改变；不要重写已经签名的 APK。

## CI 耗时与缓存

桌面 job 只编译一次 Runtime，再运行 `test:compiled` / `test:bun:compiled`；本地 `test` / `test:bun`
仍会先 build。Flutter 收尾检查只运行一次 Final，包含格式、全仓分析、源码规模和原有直接测试。
Windows 使用仓库随固定 Node 提供的 npm，不重复安装未使用的全局 npm。

全部来源的 Node/Bun 离线测试在独立 Windows job 中执行，与三平台打包并行，仍是 Release 的必需前置条件。
该 job 的 npm 下载缓存覆盖 Runtime 和所有来源 lock，仍按 lock 执行 `npm ci`，不缓存或跳过测试结果。
CI 用 `--concurrency=2` 同时检查两个独立来源；每个来源的安装、构建、Node/Bun 测试仍串行，保留限流等待。
本地默认并发为 1，可显式选择 1～8。报告记录耗时与起止时间，逐源日志独立、汇总写入串行，单源失败不跳过其余来源。

桌面新增按 OS、架构、Flutter 版本隔离的 `.dart_tool/flutter_build` 缓存；每个提交产生新 key，并恢复同工具链
最近的编译缓存。Flutter 始终重新执行构建并检查输入。macOS 另外缓存 CocoaPods 下载，Pods 安装与构建照常执行。
Bun 只缓存分发压缩包，staging 每次校验固定 SHA-512 并重新提取。保留已有 Android Gradle/Rust/Flutter 缓存和三 ABI 构建。

缓存命中、冷启动、runner 排队和真正编译耗时分别比较。结构上的重复步骤减少不等于远端总时长已经下降；
实际收益以相近代码、相同 runner 与缓存条件下的 Actions 步骤记录为准。

## Windows x64

VS Code 任务 `发布：打包 Windows EXE（Release）` 顺序执行固定 Node/npm staging、Flutter Release 构建、
`tools/verify_windows_release.ps1` 和 `tools/package_windows_release.ps1`。Actions 的 Windows job 使用同一验证和打包脚本。

输出为 `build/mgread-windows-x64.zip`、`.7z` 和 `.manifest.json`；两种归档包含同一份 Release 文件。
7z 使用固定版本与 SHA-256 校验的构建工具，ZIP 供通用解压。包内保留 Node、Bun、许可证和调试页，
Core 合并为单个入口，排除 Android/macOS 资产、类型声明和映射文件。

脚本只在新归档压缩和验证成功后替换同名输出，不把文件追加进旧归档。`tools/test_package_windows_release.ps1`
覆盖连续两次打包、删除文件不残留、错误输入保留既有 ZIP，以及 ZIP/7z 内容和摘要一致性。
原来的 `build/mg_read-windows-release` 复制目录不再是发布入口；不要发布其中的历史文件。
默认 Release 目录中的应用正在运行时，Windows 链接器可能因 EXE 被占用而失败；不会自动结束该应用。
关闭应用后可重跑发布任务。已有独立构建目录时，验证和打包脚本都支持 `-InputDirectory` 指向同一目录。

## Android

本地 VS Code 任务 `发布：打包 APK（Release）` 默认构建 ARM64，最终由 `tools/collect_release_apk.mjs`
调用共享验证器后复制为 `build/mg_read-release.apk`；验证失败时保留上次产物。
自动化调用 collector 可加 `--no-reveal`，避免打开文件管理器。Windows 需要 Python，macOS 需要 Python 3。

Actions 按 `arm64`、`armv7`、`universal` 分别构建；本地也可从仓库根目录选择相同组合：

| 包 | Flutter 参数 | 验证标签 |
| --- | --- | --- |
| ARM64，现代 64 位设备 | `--target-platform android-arm64` | `arm64` |
| ARMv7，32 位设备 | `--target-platform android-arm` | `armv7` |
| 通用 ARM 包，含前两种架构 | `--target-platform android-arm,android-arm64` | `universal` |

先使用仓库固定 Node/npm 在 `packages/mg_read_node_runtime` 执行 `npm run build`，然后执行
`flutter build apk --release` 加表中参数。验证当前输出示例：

```text
python tools/verify_android_release.py arm64 --apk build/app/outputs/flutter-apk/app-release.apk --report build/android-release/local-arm64-report.json
```

macOS/Linux 将 `python` 改为 `python3`。Actions 使用同一验证器，随构建产物保存大小、文件数和 SHA-256 报告。
多个 Flutter 构建和 Runtime staging 必须串行执行，不能同时写入共享资产或构建目录。

Android 的统一 Gradle 规则排除 Windows/macOS 运行时。Android staging 排除 `.d.ts`、`.map` 和
Windows bundle 中间目录，保留原 JS 模块路径与字节、Node 进程入口和 Javet 入口。内容指纹变化会让宿主
重新提取私有程序镜像，不删除已安装插件、书架或阅读数据。

已有 R8、资源收缩及原生 `.so` 压缩继续生效。ARM64 保留 Javet、私有 Node 与 Rust 宿主；ARMv7 保留
原有私有 Node 与 Rust 宿主策略。完整中文字体和媒体功能依赖继续交付。通用包包含两套 ABI，体积自然大于单架构包。
`.so` 安装时会解压，因此 APK 下载体积与安装后占用必须分别衡量。

`tools/test_verify_android_release.py` 覆盖误带桌面资产、开发文件、过期指纹、缺失入口和未压缩原生库；
Runtime 的 `android-runtime-staging.test.mjs` 逐文件核对发布字节，`android-runtime-import-graph.test.mjs`
检查 Android 加载图。签名验证、编译、离线测试、设备交互与远端 Actions 执行分别记录，不能互相替代。
