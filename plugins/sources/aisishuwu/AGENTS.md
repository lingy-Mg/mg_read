# 爱思书屋数据源插件增量规则

状态：开发规范。根契约和上级真实数据源插件共享规则适用；本目录只拥有爱思书屋的请求、选择器、分页
与字段投影，不修改 Runtime、Flutter 或官方模板。

- 请求、选择器、分类、搜索、详情、目录、正文或热门词解析变化后必须运行 `npm.cmd run test:live`。
- capability 日志只记录阶段、稳定分支、计数/字节投影和唯一终态，不记录来源内容或用户值。
- Windows Debug 工作区直载只证明 development Runtime 行为，不能替代 Node 门禁或 Android
  packaged-plugin 安装验收。
