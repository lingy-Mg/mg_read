# 来源发现组合

只在选择发现组件、调整来源首页或修改 `coverOrientation` 时读取；公共组件类型或宿主渲染变化改读
[discovery-contract.md](discovery-contract.md)。

## 组合原则

- 先识别官网真实区块、内容语义和数据密度，再选择宿主已有组件；不要搬运官网 DOM、样式或来源专用 UI。
- 根发现返回组合树，不让 Flutter 按来源 ID 分支。首页不能只有分类入口；若来源有稳定的最新/推荐列表，
  有界复用一组真实内容，再保留分类。没有内容证据时可以只保留入口，不能伪造推荐或榜单。
- `contentKind` 表达打开能力，`coverOrientation=portrait|square|landscape` 表达真实封面构图，两者正交。
- `coverGrid` 用于作品墙，`shelf/carousel` 用于横向浏览，`compact` 用于真实排行或高密度列表，`list` 用于
  普通纵向结果；`ranking` 只作旧输入兼容，新来源使用带真实 rank/metric 的 `compact`。
- 来源只选择语义布局和图标；Flutter 拥有圆角、间距、列数、断点、拖动、播放标识和交互。

## 实现检查

1. 根 `discover` 只接受空 target/cursor/collectionId，并返回真实内容区与入口。
2. 首页内容复用已验证的请求与解析器，按 `min(pageSize, 10)` 有界截断；二级页保留 target、cursor、
   collectionId 和分页语义。
3. 一个 contentCollection 保持单一 `contentKind`；封面方向来自真实图片，不能由媒体类型猜测。
4. 分类、section、tab 图标使用真实语义；无法判断时回退 `category/other`，不按 ID 随机生成。
5. 能用现有布局、contentKind 和 coverOrientation 表达时不扩展公共协议；确有新通用语义时才走跨层契约。

fixture 至少断言根页内容区、入口区、布局、contentKind、封面方向和一次真实请求。纯组合变化运行来源
typecheck/fixture/verify 与相邻宿主组件测试，不冒充 live；请求、选择器、分页或官网区块变化才增加网页取证和
live smoke。
