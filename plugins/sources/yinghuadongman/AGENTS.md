# 樱花动漫增量

- `src/library.mts` 拥有动漫库 `/w/` 的过滤状态、组合链接和分页判断；入口保持在 `src/index.mts`。
- 六组筛选及选项来自实际页面，不固定年份或剧情清单。`library-filters*.html` 是 2026-11-03 浏览器核对的最小行 fixture。
- 动漫库保留完整上游页（当前 35 项），不按宿主页大小提示截掉余项；分页依据真实下一页链接。
- TV 外层来源标签、二级导航和筛选弹窗属于主应用，不在来源中返回布局代码。
- 直接验证为 `test/library.test.mjs` 与 `test/runtime-contract.test.mjs`；使用固定 Node 执行 `verify` 和声明的 `test:live`。
