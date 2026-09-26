# 听书与含韩漫来源的发现覆盖记录

本记录属于 2026-09-26～27 的来源发现重构，范围为全部 5 个 audio 来源，以及 9 个包含韩漫的漫画来源。
它记录可核对的导航、分页和验证结果；当前整体状态为 **partial**，不能当作“原网站全部页面无遗漏”或 App 全链路验收。

## 已落地的入口

| 来源 | 版本 | 本次发现改动 | 发现接口检查 |
| --- | --- | --- | --- |
| i275-audio | 1.0.2 | 首页预览与全部已解析作品之间增加连续翻阅；校验 target、collection 和 cursor | 1 个目标通过 |
| tingchina-audio | 1.0.3 | 保留热门及 7 个题材首页区块；各区块剩余作品可继续加载；分类独立分页 | 9 个目标通过 |
| yueting-audio | 1.0.2 | 44 个分类／主播入口，4 种排序与完结状态组合；稀疏筛选保留原始页内位置 | 56 个目标通过 |
| qingting-radio | 1.0.2 | 北京电台预览、31 个地区及 13 个主题入口；页内剩余条目不丢失 | 44 个目标通过 |
| uaa-audio | 1.0.2 | 最新、周榜预览与 10 个分类／榜单入口；完整数组榜单读完即结束 | 10 个目标通过，榜单尾页额外检查通过 |
| p5hanman | 1.0.4 | 首页连到完整列表；扩展到 11 个入口，含韩国／其他地区与连载／完结组合 | 11 个目标通过 |
| rehanman-com | 1.0.6 | 新漫画、今日漫画、热门漫画、推荐四个原站栏目；保留每栏全部已渲染卡片 | 4 个目标通过 |
| 66manhua-cc | 1.0.8 | 原有 8 个首页栏目均可读取预览之后的条目，保留真实排名与指标 | 8 个目标通过 |
| manhuagui-com | 0.1.2 | 最新预览、分类页与追加集合统一；修复小 pageSize 跳过上游剩余作品 | 离线通过，线上连接失败 |
| baozimh-com | 1.0.6 | 26 题材、5 地区、3 状态、9 首字母选项可组合；跟随 AMP 分类分页链接 | 离线通过，线上需要脚本验证能力 |
| comicbox-comic | 1.0.2 | 从原站控件读取题材、地区、状态；保留组合条件；按真实下一页链接推进 | 129 个目标通过 |
| jmcomic | 1.0.2 | 韩漫首页预览及 8 个分类入口；首页接续使用分类集合与游标 | 8 个目标通过 |
| manwa-comic | 1.0.2 | 原站题材链接、5 个 API 频道与 3 个榜单；按接口实际每页 6 条翻页；去除重复标签与邻页重复作品 | 29 个目标通过；3 个榜单需要真实 WebView |
| uaa-comic | 1.0.2 | 韩漫、周榜、最新预览及 10 个入口；100 条完整榜单不再循环请求下一页 | 10 个目标通过，榜单尾页额外检查通过 |

来源自己生成语义组件、稳定 target/cursor 和资源描述，继续由 Flutter 宿主负责渲染。未改动 Source API、Runtime 或 Flutter。
单组分类不超过宿主的 32 项限制，较大的题材组分成多个集合，保留全部已发现选项。
漫蛙 API 游标最多保留最近 64 个原站数字 ID，用于相邻页去重；不是全站作品的永久去重数据库。

## 验证证据

- 14 个来源的类型检查、59 项离线测试及单文件插件打包通过。悦听和漫蛙在一次 `verify` 的第二次构建遇到 Windows `TS5033` 文件写入错误；对应打包分项重跑成功，漫蛙后续完整 `verify` 也通过。
- 对根发现页、子页和追加结果调用现有 Runtime 校验器；累计 319 个导航目标通过有界线上检查。此数字包含排序／筛选目标，不代表对所有组合、所有页数或所有作品逐一穷举。
- 固定 Node 的 `mgread-source-test.mjs` 快速检查：8 通过、4 partial、2 失败。已通过的是听中国、悦听、蜻蜓、UAA 听书、ComicBox、JMComic、漫蛙、UAA 漫画。
- P5、热韩漫为封面及正文资源 `notRegistered`；66 漫画为封面 `notRegistered`，漫画页图通过。它们只计 partial，不能由发现成功推导图片已验证。
- i275 快速检查发现页通过后，在抽样章节 `content.449` 返回音频地址不可用；漫画柜在根发现请求失败。
- 包子漫画的 Node 快速宿主不支持站点验证所需 JavaScript；其独立 live fixture 也没有实现 `executeJavaScript`。没有把这两个限制当作线上解析通过。
- 当前 Windows Release 主程序 `build/windows/x64/runner/Release/mg_read.exe`，版本 `0.10.5+375`，运行悦听 `--source-check` 返回 `source_not_found`、退出码 2。当前 App 没有可供该检查使用的已安装悦听源，未完成新版 14 源的 App 实际检查，也未执行 Android 验证。
- 源码规模检查仍被本次范围外的 `packages/mg_read_reader_ui/lib/src/ui/comic/comic_reader_chrome.dart` 阻塞：1172 行，超过 1000 行硬限制。本次来源文件没有新增规模违规。

完整日志和 JSON 在忽略目录 `artifacts/source-tests/discovery-refactor/`；`delivery-manifest.json` 记录版本、文件大小和 SHA-256，`delivery/` 内为 14 个可单独安装的 `.mgplugin.js`。

## 尚未覆盖或需要继续验收的部分

1. 原站账户、个人书架、阅读历史、充值／会员操作不在当前发现契约中；本次没有迁移这些页面的操作能力。
2. 听中国首页 API 另外包含主播、团队数据，本次只接入已经确认的作品栏目；主播／团队独立列表没有确认可用的公开分页接口。
3. 66 漫画、漫画柜的浏览器连接失败，未能据此穷举当前新增分类、标签或排行变体；保留已有已验证解析规则。
4. 漫蛙题材 HTML 页保留已渲染卡片；题材页后续客户端无限滚动尚未接入。5 个原有 API 频道已恢复持续分页。3 个新榜单使用有界 WebView、在结束或错误时关闭页面，仍需在真实 App 中验收。
5. 包子漫画依据浏览器可见的 `amp-list` 模板和下一页 URL 接入 `items/next`，并有三页 fixture 回归；受验证门槛限制，线上第二页尚未验收。[AMP 官方分页契约](https://amp.dev/documentation/components/amp-list/#load-more-bookmark)说明 `next` 承载下一次加载 URL。
6. 当前只承诺表内的导航与有界验证结果。站点新增入口、登录后页面、组合筛选的全部笛卡尔积、无限页数均未做穷举，不能标记为零遗漏。

## 复核入口

使用仓库固定 Node `packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64/node.exe` 和同目录 npm CLI。
各来源的 `npm run verify` 执行类型检查、离线测试和打包，`npm run test:live` 运行其独立线上 smoke。
快速检查使用 `packages/mg_read_source_testkit/bin/mgread-source-test.mjs --source <目录名> --report <报告路径>`；
App 实际检查必须使用安装了本次版本的真实 EXE `--source-check=<pluginId>`，记录 EXE 路径、版本和时间。
