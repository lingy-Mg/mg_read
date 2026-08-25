# MgRead 全局动效设计系统

## 状态与边界

本文是主应用全局动效的**开发规范**。它定义 token、减少动态效果策略、共享基础与验收方式；不把后续
feature 的计划写成已完成效果。当前事实以本工作区的 `AppMotion`、`app_router.dart` 和
`app_bottom_navigation_motion_scope.dart` 为准，本文不替代页面的业务状态机或诊断规范。

范围是 `lib/app/app_theme.dart` 的 `AppMotion`、顶层目的地路由以及无业务的共享导航动效基础。它不
授权修改 reader、library 或 discovery 页面，也不把动效作为网络、Runtime、持久化或阅读进度的替代。

## 当前审计基线

| 区域 | 已观察到的实现 | 本阶段统一后的边界 |
| --- | --- | --- |
| 顶层路由 | `CustomTransitionPage` 为主目的地做淡入；此前正反向时长相同。 | 从 `AppMotion` 取得正向和更短的反向时长；`disableAnimations` 时为零时长。 |
| 底部导航 | 根 `AppBottomNavigationMotionScope` 跨 GoRouter 页面维持胶囊，纹理有独立 controller 与 `RepaintBoundary`。 | controller 所有权单独在 motion scope；快速重定向从当前位置开始，减少动态效果立即稳定，dispose 成对释放。 |
| 弹层和菜单 | 目前由 Material 的 `showDialog`、`showModalBottomSheet`、`PopupMenu` 等默认 route 行为提供。 | 本阶段不替换页面调用；后续若定制，必须先采用本规范的时长、反向和 reduce-motion 语义。 |
| `MediaQuery.disableAnimations` | 纹理此前已停止；路由和导航其他隐式过渡尚未共享同一解析入口。 | 统一通过 `AppMotion.disablesAnimations` / `effectiveDuration` 读取，不能在各处自行解释策略。 |

这里的“已观察到”仅表示源码审计结果，不表示任何页面的视觉或真机验收已完成。

## 动效分类与产品规则

### 审美型微交互

用于按下、选中、焦点、短时显隐和紧凑布局变化。它必须短、可打断、非阻塞，且不得呈现假进度。
默认选用 `micro`、`navigationSelection` 或 `short`，以淡入配合很小的位移/尺寸变化为主；不要弹跳、
闪烁、反复呼吸或大面积缩放。

### 导航与空间关系

用于目的地切换、返回和有真实空间连续性的容器移动。前进使用 `destinationTransition` 与
`navigationCurve`，返回使用 `destinationReverseTransition` 与 `navigationReverseCurve`。路由和共享
controller 必须从当前值重新定向，返回或下一次用户操作不得等待前一次动画结束。

### 长耗时体验

请求、下载、Runtime 冷启动和持久化不绑定固定长动画。页面只能有一个有限的入场段；随后必须显示可
持续的 loading 状态，并在数据就绪后用 `loadingSettle` 快速收束。取消、超时、错误和旧数据保留均
属于原有 application 状态机，不得由动效掩盖或延迟。

### 连续装饰

仅允许低幅度、低对比、低频率的非业务装饰，例如现有底部导航纸感纹理。默认克制；当系统请求减少
动态效果、`TickerMode` 暂停（不可见）或宿主进入后台时不产生连续帧。装饰不得表达数据刷新、阅读
进度或可交互状态。

## `AppMotion` token 与组合

所有新的主应用动效先从 `AppMotion` 选择 token；不在 feature 中散落 `Duration` 或曲线常量。

| 语义 | token | 使用边界 |
| --- | --- | --- |
| 极短反馈 | `micro`（120 ms） | 状态层、局部强调；不用于内容载入。 |
| 选择切换 | `navigationSelection`（140 ms） | 紧凑的选中/取消选中。 |
| 短过渡 | `short`（180 ms） / `shortReverse`（140 ms） | 路由、面板或显隐；返回比前进更快。 |
| loading 收束 | `loadingSettle`（120 ms） | 仅在数据已经就绪后收束视觉状态。 |
| 导航胶囊 | `bottomNavigation*` | 既有顶层导航专用 token，不推广为普通页面效果。 |
| 连续装饰 | `bottomNavigationTextureDrift`（8 s）与 `bottomNavigationTextureCurve` | 仅低频背景纹理，必须可停止。 |

曲线使用 `navigationCurve`（非线性减速）、`navigationReverseCurve`（非线性加速）、`standardCurve`
（平滑进出）或纹理专用的 `easeInOutSine`。避免线性移动。普通显隐的建议组合是透明度加极小的空间
位移；缩放仅作很小的补充，不能作为整页或主要内容的入场方式。

同一可见区域内默认最多一个强调性过渡和一个低频装饰层；loading、路由和局部选中不可叠加成多层
抢焦点。动画驱动区域要最小化：静态 child 传给 `AnimatedBuilder`，绘制型装饰使用
`RepaintBoundary`，不要让动画 tick 重建整页、发起 IO 或重新计算业务 view-model。

## 减少动态效果、打断与释放

`AppMotion.disablesAnimations(context)` 是唯一的 MediaQuery 入口，`effectiveDuration` 在
`disableAnimations` 为真时返回 `Duration.zero`。隐式动画、路由和自有 controller 都必须使用它：

1. 初次进入时直接渲染终态；不得先闪现初始帧。
2. 系统偏好在运行中切换时，停止 controller 并收束至当前目标，不保留悬停中间态。
3. 重新定向时以当前 visual value 为起点，按剩余距离计算时长，并可设短时下限以避免相邻目标闪跳；不倒带、不排队。
4. 每个 controller 的 owner 在 `dispose` 中停止/释放它；连续装饰不因不可见而制造帧或重建。

共享基础只放无业务能力。`AppBottomNavigationMotionScope` 是第一个消费者：它拥有跨路由的两个
controller，renderer 只通过 `AppBottomNavigationMotion` 读取不可变的当前位置/缩放和显式动作。业务
页面若还没有第二个真实复用者，不要为未来用途抽象“万能动画框架”。

## 后续 feature 消费契约

| 后续位置 | 可消费的基础 | 本阶段没有完成的效果 |
| --- | --- | --- |
| reader | `AppMotion` 时长、曲线和 reduce-motion 解析。 | 翻页、工具栏、章节切换或阅读器手势动效。 |
| library | `AppMotion` 微交互/loading 收束规范。 | 刷新、卡片、筛选、空态的具体视觉实现。 |
| discovery | `AppMotion` 路由、sheet、结果状态规范。 | 搜索、书源、详情及菜单的具体视觉实现。 |
| dialog/menu/sheet | Material 默认行为或后续经审查的同 token 实现。 | 对现有弹层/菜单的统一替换。 |

后续接入必须保留用户操作的现有中心诊断 owner span；动效本身不新增业务事件，也不得记录输入、书名、
正文、URL、Cookie 或异常原文。

## 验收矩阵

| 层级 | 本阶段应验证 | 不能得出的结论 |
| --- | --- | --- |
| 静态 | token 类型、导入、格式、文件规模和文档链接正确。 | 真机帧率、视觉品质或系统 route 动画。 |
| Widget 自动化 | token 值、reduce-motion 终态、快速重定向和 scope dispose 后无残留 ticker。 | 页面业务流程、完整 GoRouter 转场或 Android 系统弹层。 |
| Android Integration Test | 仅在后续明确授权且用户已启动允许模拟器时，验证浅色实际交互和测试截图。 | Windows/macOS、深色模式或发布包。 |
| 平台/发布 | 由对应主机/CI 和安装签名流程单独声明。 | 本阶段未执行的平台与发布事实。 |

本阶段不运行 Android Integration Test，也不声称 reader、library、discovery、弹层或菜单已有新的
视觉效果。任何后续性能结论应以实际 profiler/设备证据报告，而不是由上述 token 推断。
