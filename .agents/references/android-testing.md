# Android 测试按需操作手册

本文只负责 Android 真机或模拟器测试的设备准备、MuMu 实例启动与 ADB 连接。仅在用户明确授权且当前任务
确实需要 Android 平台验证时读取；普通开发、静态检查和非 Android 测试不得加载本文。

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
