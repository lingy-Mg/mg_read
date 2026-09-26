# 真实数据源增量规则

根规则始终适用。本目录只拥有各来源的请求、解析、稳定身份、fixture 和私有缓存；来源名称、版本、能力和
artifact 模式以 Node 来源 `package.json.mgread` 或原生来源构建生成的 `manifest.json` 为准，文件局部边界写入口源码头。

- Node 来源构建必须输出单个 JS 并内联使用的全部第三方 npm 包，仅 Node.js 内置模块可外置。
  来源 `engines.node` 统一声明 `>=24`；构建与验证仍使用仓库固定 Node/npm。
  `.mgplugin.js` 和 `.mgplugin` 压缩包共用此要求；后者只包装单个 JS、元数据与图标，不恢复 npm 依赖。
  开发用 package/lock/node_modules 留在项目中，不进入 artifact 或 Runtime generation。
  禁止新增依赖引用扫描、动态导入检查或自定义 loader；通过构建配置落实 bundle 和禁用 splitting。
- 独立原生来源使用 `mgread-native-abi` crate 的公开 ABI，Windows DLL/Android SO 分目标构建，在
  `engine=native` 归档分发；参考 `aisishuwu-native`。原生构建与验证使用 Cargo/原生工具，不经过 Node Context。
- 先读目标来源入口、最近的来源 `AGENTS.md`、公开类型和直接测试。需要数据源契约或 WebView 专项流程时，
  只加载 `mgread-source-development` 技能路由到的一个首选参考。
- 普通来源修复只修改该来源目录；不联动 Runtime、Flutter 或模板，除非用户明确要求改变公开 Source 边界。
- 新增或整理测试时优先复用 `@mgread/source-testkit` 的公共契约、临时宿主、标准阅读链路和有界资源探测；
  来源专属选择器、固定内容事实与 live 断言仍留在来源目录。
- Fixture 由来源测试自行定义；live smoke 验证实际来源链路。
- 受保护来源只使用公开宿主能力并返回 `interaction_required`。`page.cdp` 按共享
  `@mgread/source-api` 声明使用；Android 当前返回 `unsupported`。
- Windows 使用仓库固定 Node/npm，运行目标 package 实际声明的 typecheck、离线测试和 `verify`；只有请求、
  选择器、分页或解析变化才增加明确存在的 `test:live`。
