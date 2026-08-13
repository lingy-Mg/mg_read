# MgRead 首页 UI 设计系统

## 目的与范围

本规范把首页参考图转化为可维护的 Flutter 界面规则，而不是复刻一张静态截图。它只覆盖 `features/library/presentation` 的首页展示层、`app/app_theme.dart` 中的全局语义主题，以及与首页对应的 Widget 测试。

它不授权实现 Runtime、WS/HTTP、插件安装、真实书源、Runtime Store/SQLite、文件恢复、账号、下载或阅读器数据适配。首页的展示数据是明确标注的不可变 presentation fixture；后续只可在 application/data 层把 `mg_read_runtime` Facade 返回的真实投影映射为同一 view-model，不能让 Widget 直接读取 Runtime 内部基础设施。

## 视觉目标

- 以暖白背景和低饱和琥珀色建立安静、专注的阅读入口；主操作集中在“继续阅读”。
- 用大标题、持续阅读卡、分段导航、筛选与纵向更新列表形成从当前阅读到书架动态的阅读顺序。
- 表面使用轻微色差、细边框和克制阴影分组，不用高对比的大面积渐变或装饰性图片。
- 书籍封面使用中性、可复用的 Flutter 渐变/几何占位图；不下载、复制或声称拥有真实书封面。

## 语义设计 token

所有颜色均在 `app/app_theme.dart` 的 `AppThemeTokens` 定义，页面和组件只能按语义读取它们。

| 语义 | 明亮主题 | 暗黑主题 | 用途 |
| --- | --- | --- | --- |
| `pageBackground` | 暖白 | 暖黑 | 全局画布与 AppBar |
| `surface` | 纯净浅表面 | 深色表面 | 列表与底部导航 |
| `featureSurface` | 浅杏色 | 柔和深褐 | 持续阅读与书源管理卡 |
| `mutedSurface` | 浅灰杏 | 深灰褐 | Chip、次级信息容器 |
| `divider` | 低对比暖灰 | 低对比暖灰 | 分隔线与描边 |
| `mutedText` | 中性灰褐 | 浅灰褐 | 时间、章节和辅助文字 |
| `accent` | 琥珀棕 | 柔和琥珀 | CTA、选中态与进度 |
| `accentSoft` | 浅琥珀 | 深琥珀 | 选中 Chip 与悬停表面 |
| `notification` | 可辨识红 | 柔和红 | 未读更新提示；不单独承担状态含义 |
| `focusRing` | 强调色 | 强调色 | 键盘焦点边界 |
| `cover*` | 六组主题调和色 | 六组主题调和色 | 中性封面渐变 |

尺寸只从 `AppSpacing` 与 `AppRadii` 取得：基础间距单位为 4，常用节奏为 8/12/16/24/32；触控目标不小于 48；内容最大宽度为 1184；首页卡片圆角为 24，常规表面圆角为 16，标签圆角为胶囊形。细边框为 1 个逻辑像素，阴影只用于提升可点击卡片，透明度保持低。

## 排版与图标

`AppTheme` 负责全局 `TextTheme`：页面标题使用 `displaySmall`，区块标题使用 `titleLarge`，书名使用 `titleMedium`，正文和元信息分别使用 `bodyLarge`/`bodyMedium`/`bodySmall`。主应用文字统一使用 `novel_reader_ui` 包中声明的 `MiSans`；该资源与项目提供的 `MiSansVF.ttf` 校验一致，因此复用同一份字体物料而不把约 20 MB 字体重复打入应用包。文字颜色从 `ColorScheme` 或 `mutedText` 获取，不在 Widget 中写颜色。

图标使用 Material Symbols：顶栏和列表操作为 24，导航目的地为 24，封面内的装饰图标为 28。图标按钮保持 48 的命中区，即使视觉图标较小。

## 信息层级与组件

首页由以下可组合组件构成，均接受不可变数据和显式回调：

1. `LibraryHomeShell`：应用壳、顶部操作、响应式布局、刷新状态与底部导航。
2. `LibraryContinueReadingCard` 与 `ReadingProgressBar`：当前读物、章节、进度、阅读记录和继续阅读 CTA。
3. `LibrarySectionNavigation` 与 `LibraryStatusFilterBar`：最近更新/书架切换及全部、连载、完结、本地筛选。
4. `LibraryBookCover`、`LibraryBookUpdateTile` 与 `LibraryMetadataTag`：中性封面、来源/状态标签、更新时间、未读提示与更多操作。
5. `LibrarySourceManagerCard`：书源管理的显式入口，不执行任何安装或网络操作。
6. `LibraryBottomNavigation`：首页、搜索、发现、我的四个目的地；当前仅维护可替换的 presentation-state。

`LibraryHomeViewData`、`LibraryBookUpdateViewData` 等类型以及 `LibraryHomeFixtures.preview` 仅属于展示层。fixture 带有 `isPresentationFixture` 标记，顶栏显示“界面预览”标记并提供完整说明，不能被当作真实书架、阅读进度或可用书源数量。后续真实数据接入需用 application adapter 生成同样的 view-model，并移除该说明。

## 状态与交互

- 加载：保留页面外框，使用可访问的进度语义和低干扰骨架；不跳转至空白页。
- 空：在当前基础设施仍只提供空本地投影时展示明确标注的 UI 预览，不声称已读取真实书架；真实空书架接入后使用独立空态。
- 刷新：保留已有内容，在顶端显示线性进度；失败后保留旧内容并显示可操作的错误卡。
- 错误：只展示 `AppError` 归一化文案和可重试操作，绝不显示原始异常、书籍正文、URL、Cookie 或令牌。
- 点击、悬停、焦点、按下和禁用状态由 Material 状态层和主题 token 表达；CTA、列表行、菜单和导航均提供语义标签。未接入的动作只触发可替换 callback 或明确的本地提示，不发请求、不写入持久化状态。
- 动画限于 Material 状态反馈与短时布局过渡；不使用自动滚动、不可取消的长动画或会干扰阅读的闪烁。

## 响应式与输入规则

| 宽度 | 布局 | 输入与可访问性 |
| --- | --- | --- |
| `< 720` | 单列；持续阅读卡先于更新列表；底部导航固定 | 触摸优先，所有操作至少 48 逻辑像素 |
| `720–979` | 单列但增加边距，卡片内容可横向排布 | 触摸与鼠标并用；可见焦点环 |
| `>= 980` | 最大宽度 1184；持续阅读与更新列表并列，信息层级不改变 | Tab 按视觉顺序遍历；Enter/Space 激活；鼠标悬停仅补充不替代语义 |

所有正文允许系统文字缩放；宽屏不无限拉伸文本行，窄屏封面和元信息可压缩或换行但不遮挡 CTA。颜色不是状态的唯一表达：选中项同时改变文本/边框，未读项同时保留“有更新”的语义标签。

## 验收要求

- Widget 测试覆盖主要语义、继续阅读 CTA、底部导航、窄/宽布局、明亮/暗黑主题和代表性键盘焦点或触摸操作。
- Golden 使用同一 MiSans 与 Material Icons 字体，在固定 `390×844` 紧凑亮/暗主题和 `1280×900` 宽屏暗主题下校验；本阶段不以 Golden 代替交互测试。
- 自动化通过不代表桌面运行、macOS 平台或 Android 真机验收；交付报告必须分别说明已执行和未执行的证据。
