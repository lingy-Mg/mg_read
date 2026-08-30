# 来源发现组合与视觉语义

只在选择组件、调整布局或修改爱丽丝/速读谷等真实来源发现输出时读取本文件。

## 组合原则

- 先识别官网真实区块和数据密度，再选择宿主已支持的语义组件；不要把官网 DOM 结构或样式直接搬进插件协议。
- 首页返回一棵组合树，不让 Flutter 按来源 ID 写专用页面分支。
- `vertical` 子组件占满整行并使用宿主区块间距。`group.grid` 只用于适合并排的小面板。
- `coverGrid` 在紧凑手机为三列、较宽应用布局为四列，更宽桌面可继续增密；标题单行省略。`shelf` 保持横向滚动，`compact` 保持整行榜单密度。
- `categoryCollection.grid` 适合入口矩阵，`chips` 适合题材快速筛选；图标由语义名选择，不按 ID 哈希随机生成。
- 排行内容统一使用带真实 `rank/metric` 的 `compact`；`ranking` 只为旧插件输入兼容，不再作为新来源的
  视觉选择。排行榜组使用整行 `vertical`，避免把可读列表压缩成并排小面板或产生嵌套 surface。

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
