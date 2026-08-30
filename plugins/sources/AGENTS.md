# 真实数据源增量规则

根规则始终适用。本目录只拥有各来源的请求、解析、稳定身份、fixture 和私有缓存；来源名称、版本、能力和
artifact 模式以各自 `package.json.mgread` 为准，文件局部边界写入口源码头。

- 先读目标来源入口、最近的来源 `AGENTS.md`、公开类型和直接测试。需要数据源契约或 WebView 专项流程时，
  只加载 `mgread-source-development` 技能路由到的一个首选参考。
- 普通来源修复只修改该来源目录；不联动 Runtime、Flutter 或模板，除非用户明确要求改变公开 Source 边界。
- Fixture 只保存确定性、脱敏的最小结构；live smoke 不保存响应。日志不包含 URL/query、用户值、标题、
  HTML、正文、Cookie、token、凭据、原始异常或绝对路径。
- 受保护来源只使用公开宿主能力并返回 `interaction_required`；不得新增 Cookie API、CDP、DOM 合成点击、
  token 抽取/回放或绕过。
- Windows 使用仓库固定 Node/npm，运行目标 package 实际声明的 typecheck、离线测试和 `verify`；只有请求、
  选择器、分页或解析变化才增加明确存在的 `test:live`。
