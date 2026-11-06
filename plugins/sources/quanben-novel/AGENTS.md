# 全本小说网来源增量规则

- 页面和公开目录 API 仅访问 `https://www.quanben.io`；图片仅登记 `img.c0m.io/quanben.io/upload/thumbnail` 已核验路径。
- 作品 ID 保留上游 URL slug，章节保留数字键；不按标题生成 slug，不用数组下标替代章节 ID。
- 目录必须组合 HTML 首部、公开 JSONP 中段和 HTML 尾部，并验证响应作品 ID；不只返回静态首尾。
- JSONP 仅剥壳后 JSON.parse，不执行脚本；回调编码是公开接口参数，不迁入 Cookie 或验证令牌。
- 缺失中段、重复、正文占位、目录/章节超限均失败，不静默丢内容；推荐追加使用有界快照。
- 变更执行 `verify`、`test:live` 和单源快速检查；旧主程序聚合资源报告仍归一化为 partial。
