# 爱思书屋数据源插件增量规则

状态：开发规范。根契约和上级真实数据源插件共享规则适用；本目录拥有爱丽丝书屋的请求、选择器、分页、
字段投影，以及供其他数据源复用的标准 artifact 构建器；不修改 Runtime、Flutter 或其他数据源行为。

- 请求、选择器、分类、搜索、详情、目录、正文或热门词解析变化后必须运行 `npm.cmd run test:live`。
- capability 日志记录阶段、稳定分支、计数/字节投影和唯一终态。
- 发现根页、子列表和追加在封面代理后按 UTF-8 JSON 字节压缩展示投影；保留作品、稳定身份、分页和封面，
  不修改详情缓存。预算测试使用有实际长度的 opaque 代理地址，不能只依赖短占位 URL。
- Windows Debug 工作区直载只证明 development Runtime 行为，不能替代 Node 门禁或 Android
  packaged-plugin 安装验收。
