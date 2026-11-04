# 桌面 Node / Bun 双运行时

## 产品行为

Windows x64 和 macOS arm64 同包内置 Node 26.10.0 与 Bun 1.4.4，无需用户安装额外运行环境。
在「我的 → 设置 → JavaScript 运行时」选择后端，默认保留 Node。选择立即持久化，界面区分当前运行和
待启用状态；可立即重启、稍后重启，或重新选择当前后端取消待切换。重启前提示阅读、播放、下载会中断。

两种 JS 后端共用已安装数据源、插件配置和缓存。一次只运行一种 JS 后端；Windows 原生 Rust 数据源
保持独立并存。运行状态显示实际 Bun 版本及 JS 堆占用，不把 Bun 的 Node 兼容版本当成真实 Node 版本。
不承诺 Bun 对每个第三方来源都更快；出现来源兼容问题时可切回 Node。

## 所有权与启动链路

1. App `main` 消费私有重启参数并等待旧进程退出，再初始化 Flutter 与桌面启动偏好。
2. Runtime-owned `DesktopRuntimeSettings` 冻结当前后端；设置写入原子替换，只影响下次进程启动。
3. 同一 Facade/Supervisor 按冻结选择解析包内 helper，沿用 ready → HTTP readiness → WS hello 握手。
4. Bun 握手独立验证 1.4.4；保留实际 Node 兼容层版本。禁止回退系统 PATH、隐式下载依赖和 dotenv。
5. Bun HTTP 使用打包 Undici，以保留代理、SOCKS、HTTP/2、流式资源、超时与取消语义。
6. 开发目录构建仍调用固定 Node/npm；来源 API、原生引擎分流和 WebView 桥接契约保持一致。

## 失败与恢复

| 场景 | 行为 |
| --- | --- |
| 没有偏好、未知值、损坏或不可读 | 使用内置 Node，应用仍可打开 |
| 安装包缺少 Bun | 禁用 Bun 选项并说明原因；保存的 Bun 选择恢复到 Node |
| 保存失败 | 保持原选择，显示可重试错误 |
| 自动重启失败 | 保留已保存选择，允许重试或手动退出重开 |
| Bun 启动失败、错误二进制或版本不符 | 返回明确 Runtime 错误，不伪造健康状态；用户可关闭错误提示并切回 Node |
| 多请求同时首次调用 | 同一 Supervisor 单次启动；取消、退出、代理重绑沿用既有生命周期 |

## 打包与自动验证

- `stage-bun-runtime.mjs` 下载精确官方 `@oven` 包并验证 SHA-512；缓存也重新校验、重新解包。
  helper 和 Bun 许可证跟随平台资产。Windows 正常包缺少任一 helper 时构建失败。
- macOS 将两种 helper 放入 `Contents/MacOS`，使用专用 JIT entitlements 及 hardened runtime 签名，
  然后重新签名被修改的 `App.framework`。JIT 权限依据
  [Bun 官方签名指南](https://bun.sh/guides/runtime/codesign-macos-executable)，不包含调试 task 权限。
- `npm run test:bun` 执行共享桌面行为用例；Android 和 Node 专用工具链测试继续由 Node 套件承担。
- `npm run verify:staged-bun` 从独立目录启动已打包 helper，验证身份、健康、真实来源调用和关闭。
  CI 还把 `MGREAD_BUN_BUNDLE_ROOT` 与 macOS 的 `MGREAD_BUN_EXECUTABLE` 指向最终 App，检查签名后的产物。
- Flutter 直接测试覆盖偏好持久化、设置页、重启等待、并发单次启动、Node → Bun → Node 共用数据、
  来源发现/搜索/详情/目录/内容/导出、代理重绑及 Bun 与原生引擎并存。

Windows 命令使用仓库固定 Node；先完成 staging 再构建 Flutter，禁止并发重写构建正在读取的资产。
macOS 签名执行、Gatekeeper、公证和实机结论必须来自 macOS 运行证据，Windows 字节一致性测试不能替代。
