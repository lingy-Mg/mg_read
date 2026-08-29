# 速读谷数据源插件增量规则

状态：开发规范。根契约和上级真实数据源插件共享规则适用；本目录只拥有速读谷的请求、选择器、分页与
字段投影，不修改 Runtime 或 Flutter。

- 请求、选择器、分类、搜索、详情、目录或正文解析变化后必须运行 `npm.cmd run test:live`。
- live smoke 只验证最小必要的分类、搜索、详情、完整目录和正文路径，不保存返回 HTML 或正文。
- Windows Debug 工作区直载只证明 development Runtime 行为，不能替代 Node 门禁或 Android
  packaged-plugin 安装验收。
