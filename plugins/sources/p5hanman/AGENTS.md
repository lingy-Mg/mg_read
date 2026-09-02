# P5 韩漫站点增量规则

- 入口 `https://www.4p5mha.work` 会重定向到当前服务域；内容 ID 只使用 `/book/{id}` 与
  `/chapter/{id}` 的数字 token，不能把轮换域名作为身份。
- 列表解析当前 `.mh-item` 与排行 `.mh-itme-top`；详情章节只取 `.detail-list-select`，避免把顶部
  “开始阅读”按钮重复计入目录。
- 漫画页只接受 `.comicpage img.lazy[data-original]` 的受控图片域，不使用 `src` 中的占位图。
- 所有封面和章节图必须通过 `ctx.resource.proxy`；resource 请求携带生成时的 Referer，并按
  `cover|page` 用途分别校验来源域和 Referer 路径。
- Fixture 只保留虚构名称、数字路径和短图片字节。
