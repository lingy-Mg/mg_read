# 来源发现组合与视觉语义

只在选择组件、调整布局或修改爱丽丝/速读谷等真实来源发现输出时读取本文件。

## 组合原则

- 先识别官网真实区块和数据密度，再选择宿主已支持的语义组件；不要把官网 DOM 结构或样式直接搬进插件协议。
- 首页返回一棵组合树，不让 Flutter 按来源 ID 写专用页面分支。
- 首页不能只有分类入口。对仅有分类的简单来源，优先复用一个稳定的“最新/推荐/综合”列表请求，最多取
  10 条组成一个内容区，再保留分类区；不要为凑首页并发抓取多个分类，也不要伪造推荐、榜单或来源字段。
- `vertical` 子组件占满整行并使用宿主区块间距。`group.grid` 只用于适合并排的小面板。
- `coverGrid` 在紧凑手机为三列、较宽应用布局为四列，更宽桌面可继续增密；标题单行省略。`shelf` 保持横向滚动，`compact` 保持整行榜单密度。
- `categoryCollection.grid` 适合入口矩阵，`chips` 适合题材快速筛选；图标由语义名选择，不按 ID 哈希随机生成。
- 排行内容统一使用带真实 `rank/metric` 的 `compact`；`ranking` 只为旧插件输入兼容，不再作为新来源的
  视觉选择。排行榜组使用整行 `vertical`，避免把可读列表压缩成并排小面板或产生嵌套 surface。

## 按媒体选择内容组件

同一个 `contentCollection` 应保持单一 `contentKind`。来源只选择语义布局，并按官网真实图片声明
`coverOrientation=portrait|landscape`，不传尺寸或样式。媒介类型与封面方向相互独立：视频可以是竖向海报，
小说、漫画、音频也可以使用横向封面；不得用 `contentKind` 猜测横竖组件。

| 媒体 | 首页优先选择 | 二级普通列表 | 排行/高密度 | 封面语义 |
| --- | --- | --- | --- | --- |
| 小说 | 推荐可用 `carousel`；更新用 `shelf`；新书/完结可用 `coverGrid` | `list` | 带真实名次的 `compact` | 竖版，作者、章节、字数 |
| 漫画/写真 | 作品墙优先 `coverGrid`；更新也可用 `shelf` | `list` | 带真实名次的 `compact` | 竖版，作者/画师、话数 |
| 音频 | 热门节目或更新优先 `shelf`；专辑墙可用 `coverGrid` | `list` | `compact` | 竖版，主播、集数 |
| 视频 | 作品墙用 `coverGrid`；推荐可用 `shelf`/`carousel` | `list` | `compact` | 按来源真实图片声明竖向或横向，不附加封面播放语义 |

当前宿主按 `coverOrientation` 把 `coverGrid`、`shelf`/`carousel`、`list` 和详情头路由到独立的竖向或横向
通用组件；`compact` 不依赖封面方向。横向组件不显示播放图标或“视频”标识，播放能力只由 `contentKind` 和
详情动作决定。插件仍必须正确返回 `contentKind`，不能依靠标题、来源 ID、布局名或封面方向让宿主猜媒体类型。
`featured` 只在确有少量强推荐且数据足够时使用，不应成为所有简单首页的默认项。

## 一次成型检查

在修改来源前先写下官网区块到协议组件的映射，再实现并逐项核对：

1. 根 `discover` 只接受 `target/cursor/collectionId` 全为 `null`，返回“真实内容区 + 分类/榜单入口”；内容为空时
   可以只保留入口，不能合成假条目。
2. 首页内容复用已经验证的请求与解析器，并按 `min(pageSize, 10)` 有界截断；二级页继续保留原 target、cursor、
   collectionId 和分页语义。
3. `ContentSummary.contentKind` 与来源媒体一致，`coverOrientation` 与真实封面方向一致；分类、section 图标
   使用真实语义，无法可靠判断时回退 `category`/`other`，不要随机映射。
4. `list` 不代表“小说列表”，只表示纵向结果流；宿主先按 `coverOrientation` 选择横向或竖向条目，竖向条目
   再按 `contentKind` 解释章节、话数或集数等来源元数据。
5. 不重复实现宿主已有的圆角、间距、断点、横竖比例或 Material 图标；封面组件不承载播放层。需要新视觉语义
   时先判断是否能由现有布局、`contentKind` 与 `coverOrientation` 表达。
6. fixture 至少断言根页内容区、入口区、布局、媒体类型、封面方向和一次真实请求；宿主 widget/golden 分别断言
   横向与竖向组件，避免只验证 JSON 形状却路由到错误方向。

## 爱丽丝当前编排

- 重磅推荐：`carousel`
- 原创新作：`coverGrid`
- 导航组合：`vertical`
  - 按题材找书：`categoryCollection.chips`
  - 热门榜单：`categoryCollection.grid`
- 热门推荐小说：`compact`

榜单图标固定为：本日 `dailyRanking`、本周 `weeklyRanking`、本月 `monthlyRanking`、总榜 `allTimeRanking`。题材按科幻、经典、奇幻/玄幻、系统、武侠、都市、乡村、同人、校园、穿越、言情等真实语义映射；无法可靠分类时使用 `category`。

## 速读谷当前编排

- 正在热更：`shelf`
- 阅读排行：整行 `compact`
- 完结精选：整行 `coverGrid`
- 探索分类：`categoryCollection.chips`

分类按稳定来源 ID 映射都市、玄幻/奇幻、轻小说、历史、科幻、游戏、悬疑、体育、军事、武侠、乡村、言情等图标；不改变来源 target 和 URL。

## 扩展方式

新增来源默认参考爱丽丝，并按漫画、WebView、音频或视频能力选择当前同类真实数据源；仓库不维护空白官方模板。若现有布局能表达内容，组合已有组件；只有新的通用内容语义确实无法表达时才扩展公开枚举，并完成发现契约中的跨层清单。来源请求或选择器变化要用官网/live evidence 验证，纯布局字符串变化不等于网络行为变化。

## 最小验证

纯组合变化运行来源 typecheck/fixture/verify，并检查宿主对应组件测试；不冒充 live 网络验证。选择器、请求、
分页或来源区块本身变化时，先按真实网页探测取得证据，再运行该来源明确存在的 live smoke。
