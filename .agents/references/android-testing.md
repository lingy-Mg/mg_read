# Android 测试按需操作手册

本文只负责 Android 真机或模拟器测试的设备准备、MuMu 实例启动与 ADB 连接。仅在用户明确授权且当前任务
确实需要 Android 平台验证时读取；普通开发、静态检查和非 Android 测试不得加载本文。

## 既有应用数据保护

- 不得用集成测试 APK 覆盖设备上的正式应用。使用 `--dart-define=MGREAD_APPLICATION_ID_SUFFIX=tvqa`
  等合法后缀；参数值不带前导点，Gradle 会自行添加分隔点。
- 安装前必须用 Android SDK 的 `aapt2 dump badging` 核对已构建 APK 的真实包名；Dart define 或源码中的
  applicationId 不能代替 APK 核验。正式包名为 `com.mgread.mg_read`，不能作为测试安装目标。
- `flutter drive` 默认结束时会卸载应用。必须使用已核验的 `--use-application-binary` 和
  `--keep-app-running`，避免工具按源码包名误清理正式应用；测试后仅清理已核验的测试包。
- 测试失败不得通过卸载正式应用、清空数据或重置设备修复。

## 设备选择

1. 优先使用已经连接且状态为 `device` 的 `emulator-5556`。
2. 否则使用任务指定的 MuMu 实例。不得根据列表顺序臆测实例 index，也不得把某个 ADB 端口视为永久固定。
3. 不得重置设备，也不得用桌面输入、坐标或 `adb input` 取证。

## 启动 MuMu 实例

本机 MuMu 12 管理器路径为：

```text
C:\Program Files\Netease\MuMu Player 12\nx_main\MuMuManager.exe
```

1. 执行 `MuMuManager.exe info -v all` 查询实例，以任务指定的名称或 index 唯一确认目标。
2. 如果目标实例尚未启动，执行 `MuMuManager.exe control -v <index> launch`。测试需要时允许自动启动，
   但不得顺带关闭、重启或操作其他实例。
3. 轮询 `MuMuManager.exe info -v <index>`，直到 `is_android_started` 为 true。
4. 从实例信息读取 `adb_host_ip` 和 `adb_port`，将 `<host>:<port>` 作为该实例的实际 ADB 地址。

## 连接 ADB

1. 优先使用当前可用的普通 adb；普通 adb 可以直接连接 MuMu 的 ADB 地址。
2. 先检查 `adb devices`。如果目标地址尚未连接，主动执行一次 `adb connect <host>:<port>`，再确认其状态为
   `device`。任务明确给出 `127.0.0.1:7555` 时，同样按这个流程连接，无需 MuMu 专用 adb。
3. 只有普通 adb 不可用时，才回退到 MuMu 自带的 adb：

   ```text
   C:\Program Files\Netease\MuMu Player 12\nx_main\adb.exe
   ```

4. `kill-server` 不是连接 MuMu 的前置步骤；仅在已经确认 adb server 异常、且当前测试确需修复连接时使用。

## 证据边界

交付时单独报告设备标识、Android 版本、实际 ADB 地址、执行过的真实流程和结果。静态检查、自动化测试、
Windows 运行或仅成功连接 ADB，均不能替代 Android 真实流程证据。
