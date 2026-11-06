# 樱花动漫增量

- `src/library.mts` 拥有动漫库 `/w/` 的过滤状态、组合链接和分页判断；入口保持在 `src/index.mts`。
- 六组筛选及选项来自实际页面，不固定年份或剧情清单。`library-filters*.html` 是 2026-11-03 浏览器核对的最小行 fixture。
- 动漫库保留完整上游页（当前 35 项），不按宿主页大小提示截掉余项；分页依据真实下一页链接。
- `src/discovery.mts` 拥有单页栏目面板边界：今日更新、热榜、新片上线只取各自首面板；周表按原页七天分组。
- 单页栏目保留完整内容，每集合最多 50 项，超出时在同文档分集合；不返回 continuation，拒绝遗留翻页 cursor。
- TV 外层来源标签、二级导航和筛选弹窗属于主应用，不在来源中返回布局代码。
- `src/hls-policy.mts` 为 HLS 登记声明式差异分析策略；Runtime 执行路径/命名/字符/时长投影、直方图分离和 TS 时间戳复核。不得恢复广告域名、目录或注释黑名单；普通切换与证据不足的片段保留。
- 直接验证为 `test/discovery.test.mjs`、`test/library.test.mjs` 与 `test/runtime-contract.test.mjs`；`test/discovery-live.test.mjs` 检查所有栏目、四类动漫库的首页/追加/末页及六组公开筛选选项。使用固定 Node 执行 `verify` 和声明的 `test:live`。
- 动漫库筛选值使用站点实际的 ASCII/CJK 字符范围；Android Javet 不支持 `\p{L}` / `\p{N}` 等 Unicode 属性转义，不能只用桌面 Node 编译通过证明兼容。实际发布包的升级回归见根 `integration_test/android_source_update_activation_test.dart`。
