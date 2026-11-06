# WNACG 来源增量规则

- 页面限 `www.wnacg.com`，缩略图限 `t1` 至 `t9.qy0.ru/data/t`，页图限 `img1` 至 `img9.qy0.ru/data`。
- aid 是图集及单个图集章节的上游身份；页 ID 取路径摘要，站点图片时效签名不进入稳定 ID。
- 下拉脚本只解析图片数据，不执行 eval/旧 JavaScript；详情页数必须与唯一页图数完全一致，广告域名不登记。
- 每次正文读取重取详情及下拉数据以刷新站点提供的资源签名；不生成签名、不读取会话 Cookie，不持久化图像。
- 页数通过真实属性展示，不把页数当字数；CDN 会协商 JPEG/WebP，未知页图 MIME 返回 null。
- 变更执行 `verify`、`test:live`、单源快速检查，封面和页图单独验证；旧 EXE 的聚合资源验收记 partial。
