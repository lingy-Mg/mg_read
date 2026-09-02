# 真实数据源增量规则

根规则始终适用。本目录只拥有各来源的请求、解析、稳定身份、fixture 和私有缓存；来源名称、版本、能力和
artifact 模式以各自 `package.json.mgread` 为准，文件局部边界写入口源码头。

- 先读目标来源入口、最近的来源 `AGENTS.md`、公开类型和直接测试。需要数据源契约或 WebView 专项流程时，
  只加载 `mgread-source-development` 技能路由到的一个首选参考。
- 普通来源修复只修改该来源目录；不联动 Runtime、Flutter 或模板，除非用户明确要求改变公开 Source 边界。
- 新增或整理测试时优先复用 `@mgread/source-testkit` 的公共契约、临时宿主、标准阅读链路和有界资源探测；
  来源专属选择器、固定内容事实与 live 断言仍留在来源目录。
- Fixture 只保存确定性的最小结构；live smoke 不保存响应。
- 受保护来源只使用公开宿主能力并返回 `interaction_required`；不得新增 Cookie API、DOM 合成点击、
  token 抽取/回放或绕过。`page.cdp` 可按共享 `@mgread/source-api` 声明使用，但不得用于挑战绕过或
  token 抽取/回放；Android 当前返回 `unsupported`。
- Windows 使用仓库固定 Node/npm，运行目标 package 实际声明的 typecheck、离线测试和 `verify`；只有请求、
  选择器、分页或解析变化才增加明确存在的 `test:live`。
