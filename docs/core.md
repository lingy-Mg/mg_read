# MgRead 核心规范

本文件只保存跨多个文件或 package 的稳定边界。先读目标文件头、最近的 `AGENTS.md`、公开类型和直接测试，
再由[最小路由](development/README.md)只打开一个相关章节。文件局部事实不得复制到这里。

## 决策与范围

- 指令优先级：用户当前要求 → 本核心规范 → 最近的 `AGENTS.md` → 公开契约与测试。
- 架构变化只修改本文件的相关章节，并同步公开类型、测试和调用方；历史原因由 Git 保存，不建立实现快照、
  阶段规划或重复 README。
- `mg_read` 是唯一 Flutter 主应用。每个任务只完成用户指定切片，不顺手扩展未来能力。

## 仓库与所有权

```text
lib/                               Flutter 主应用
packages/mg_read_reader_ui/        小说/漫画阅读器
packages/mg_read_audio_player/     音频播放器
packages/mg_read_video_player/     视频播放器
packages/mg_read_node_runtime/      Node.js Runtime Core
packages/mgread_plugin_runtime/     Flutter Runtime Facade 与平台宿主
plugins/sources/aisishuwu/          默认 Node 数据源参考实现与 artifact 构建器
plugins/sources/                    真实数据源及其他能力参考实现
```

- 主应用依赖方向为 `app -> features -> core/shared`。Widget 不直接访问网络、数据库、文件或 Runtime
  transport，也不在 `build()` 中发请求或写状态。
- 主应用只消费 Runtime 的版本化强类型 Facade；不得创建 raw Client/DTO/WS/HTTP handler，也不得向
  Runtime 注入主应用数据库、路径、Cookie、文件服务、callback、端口或平台通道。
- package 公开入口是唯一跨边界入口；禁止深层导入其他 package 的 `src/`。

## 主应用持久化与 Content Library

- `AppPersistence` 是 metadata 权威；schema、版本和容器生命周期只由 core persistence 管理。
- `ContentLibrary` 拥有书架、目录、正文、受控文件、小说/漫画/音频/视频进度和书签；Runtime 不打开
  主应用数据库，也不取得内容路径。
- 书架上限由 `bookshelfMaxItemCount` 统一管理；新增在 metadata 事务内校验，更新不占新名额。
- 受控对象先写入并校验，再通过 metadata revision CAS 切换引用；已提交 metadata 是恢复权威，无引用对象
  由有界 maintenance/GC 清理。
- 目录刷新使用 pending snapshot 后一次切换 active，并以稳定 ID/keyset cursor 维护；不得把 offset、页码、
  数组位置或全量内存载入作为持久权威。
- Runtime 结果只有经公开 Facade 和强类型 adapter 校验后才能入库；没有公开协议时保持 `unsupported`。
- 宿主详情快照必须有界且 JSON 兼容。

## Runtime 与平台宿主

- 每个应用进程只有一个 Node Runtime 和一个 V8 VM；禁止 Worker、插件子进程、第二 VM、Engine Pool、
  native addon 和自定义 loader。
- Runtime 独立拥有 Node Core、Android Javet、desktop Node launcher、Supervisor、内部控制/数据面、Plugin
  API、安装、私有数据根、瞬时诊断和 Flutter Facade。
- `packages/mg_read_source_api` 是数据源宿主上下文和 WebView 类型的唯一公开声明包；Runtime 实现与所有
  数据源必须引用或同步它，来源不得复制 Context/WebView 子集。
- Runtime 数据只包含不可变安装版本、插件私有 data/cache、Cookie、临时资源和运行状态，不包含主应用
  业务权威。installed 版本只在冷启动激活；development 变化先回收旧 VM，再启动唯一新 Runtime。
- Runtime 来源 HTTP 客户端默认继承系统代理，也可接收应用传入的瞬时上游 HTTP、HTTPS 或 SOCKS5 代理，
  覆盖 `ctx.http.fetch` 与 Runtime 代取的来源资源；不得增加 Flutter 回环转发服务器。关闭自定义覆盖后，新请求
  恢复系统代理，系统未配置代理时才直连。两类来源请求在未显式提供 `User-Agent` 时统一使用 Runtime 固定的
  reduced Windows 桌面 Chrome UA；数据源显式值优先。
- Windows Node Runtime 生产启动默认携带 `--use-env-proxy`，只传入 `HTTP_PROXY`、`HTTPS_PROXY`、
  `NO_PROXY`，缺失项由 Windows 手动代理补齐并始终排除 loopback。来源 HTTP 的显式 dispatcher 优先于系统
  代理；Android 由平台代理读取能力把当前网络代理应用到来源 HTTP。
- 视频和音频代理只控制 MediaKit 播放器到 Runtime 回环资源 URL 的本地一跳，并且只接受 HTTP 代理。
  Windows 可显式启用“强制代理本地 Runtime”：宿主临时从进程 `no_proxy` 删除 loopback 规则，同时更新 Win32
  环境和 Windows CRT，关闭后恢复原值；该开关不改变 Runtime 到外部媒体源的请求路由。
- Runtime 控制信息由 Runtime 内部管理；控制帧有界，大资源走 HTTP 数据面。
- macOS arm64 从 App bundle 启动固定 Node/npm，用父进程看门狗绑定子进程生命周期；已安装数据源的导入、启停、发现、搜索、详情、目录、内容、传输、缓存以及工作区开发目录构建属于 desktop 共同能力。
- `ctx.webview` 每个数据源只有一个宿主页；普通操作串行，
  显隐/关闭走控制旁路；超时与取消必须清理结果但保留可复用页面。
- `ctx.webview` 提供 Windows WebView2 专用的原始 `page.cdp(method, params)` 通道，Android 返回
  `unsupported`。

## 标准插件项目、artifact 与安装

- 数据源是可信 Node.js 24 ESM 项目，`package.json.mgread` 是唯一 MgRead 元数据。
- 仓库不维护空白官方模板；新数据源默认参考 `plugins/sources/aisishuwu/`，漫画、WebView、音频或视频
  按能力参考现有同类真实数据源。公共契约仍以 Runtime 类型和直接测试为准，不以某个来源副本为权威。
- `single-file` 与 `archive` 是独立发布模式。前者生成 `.mgplugin.js` 并内联可打包依赖；后者生成
  `.mgplugin` 并保留 lock 恢复语义。两者不互相回退，也不携带源码或 `node_modules`。
- artifact 必须确定性、有界，并携带可复核的 descriptor、大小和 SHA-256；传输和安装两端都复核。
- 安装写入不可变版本并原子切换；失败保留当前版本。不得在安装期运行任意脚本或求解未锁定依赖。
- 插件缓存使用来源声明的展示投影策略；stale 可离线读取，刷新异步单飞，缓存失败按 miss 处理。

## 插件内容 API

- 统一称“数据源”；只有项目、artifact、安装、启停和 Runtime 生命周期使用“数据源插件”。
- 调用链为 `discover/search -> contentId -> getDetail/getChapters -> chapterId -> getContent`。ID、cursor 和
  target 是插件内稳定不透明值，URL、标题、数组位置和页码不得作主键。
- 固定键必须存在；未知可空标量显式为 `null`，`0` 不等于未知，集合始终是数组。Runtime 不修补无效响应。
- 数据源只可通过 `ctx.errors.raise` 抛出白名单稳定错误码；Runtime 负责统一处理其他异常。外部媒体解析失败
  使用 `source_media_resolution_failed`。
- 数据源只返回允许的语义组件、布局和图标名。`contentKind` 表达小说、漫画、音频、视频等媒介能力；
  `coverOrientation=portrait|landscape` 独立表达真实封面的横竖方向，二者不得互相推断。Flutter 宿主按封面方向
  选择两套通用组件，并拥有主题、尺寸、断点、可访问性、导航和交互实现；横向组件不等同于视频播放器入口，
  不附加播放图标或视频标识。旧 Plugin API v1 输出缺少该键时只在 Runtime 边界执行兼容归一化，新来源必须声明。
- 热门词必须来自来源；默认进入搜索页不触发搜索，只有用户提交或点击建议才执行。
- 目录完整、有序且 ID 唯一。小说正文使用 `text`；漫画 `pages`、封面及音视频只登记由数据源校验过的
  `kind + url + headers` Runtime proxy 请求。loopback URL 以明文可逆 Base64URL JSON 自包含该请求，不依赖
  进程内 token 映射；此编码不提供加密或认证。Runtime 持有上游 HTTP 请求、取消和正文流，数据源不得导出
  `resource` 字节能力或缓冲媒体正文；大资源不进入插件返回值或控制面。
- fixture 只保留选择器、分页、null/0/空集合和错误分支需要的最小结构。
- 开发期由纯 Node.js `mg_read_source_testkit` 直接检查插件公开契约和 live 链路；正式 Windows App 内置自检
  经生产 `SourceContentGateway -> Runtime Facade -> Runtime -> 已启用插件` 验证发现、搜索、详情、完整目录、
  首/中/末内容和资源代理。App 页面与正式可执行文件 CLI 复用同一引擎；两层证据不得互相替代。
- 受保护来源的页面状态和响应内容由数据源根据实际业务自行判断和处理。

## 阅读器

- 小说/漫画阅读器、音频播放器和视频播放器互相独立，不共享媒体模型、Controller 或 UI。
- package 只拥有会话、交互和生命周期；宿主拥有数据、路由和授权资源。package 不接触账号、支付、DRM、
  主应用数据库或下载权威。
- 音频后台会话由主应用根层持有：返回时按持久化偏好询问、继续或停止，继续后以应用内播放条恢复，Android
  同时使用系统媒体通知；打开视频前必须先暂停并移除现有后台音频。不得为此申请系统悬浮窗权限。
- 文本锚点为 `chapterId + paragraphId + characterOffset`，漫画为
  `chapterId + imageId + imageFraction`；视频分组使用中性的 `groupId + episodeId`。
- 视频目录只保留安全的分组与选集元数据；签名或会话型播放资源由 `VideoEpisodeDataSource` 仅为当前选中集
  按需解析。宿主展示状态重建必须复用同一 DataSource 与进度 Store，不得触发整场播放器 reload。
- Observer 只请求宿主动作；未注册 capability 隐藏。异步域必须有世代/取消，资源成对释放。

## UI、状态与组件

- 当前只开发和验收浅色模式；保留既有深色实现，不自主扩展深色设计。
- 页面只组合布局和状态。复用顺序为 feature 内组件 → `shared/`；只有跨两个以上 feature 的无业务模式
  进入 shared。
- 全局视觉通过 `AppTheme`、`AppThemeTokens`、`TextTheme`、`AppSpacing`、`AppRadii` 和既有组件扩展，
  页面不建立平行 token 系统。
- 组件接收不可变数据和显式回调。异步刷新保留稳定可见数据，过期或 dispose 后结果不得覆盖当前状态。
- 来源字段缺失时显示 `--` 或隐藏，不伪造数据、热门词或能力。

## 诊断

- App 诊断默认关闭；显式启用才创建 writer。历史文件冷存储，只在用户选择后有界读取。
- 诊断字段和显式捕获字节按契约保存；错误终态可额外保存技术上下文。
- 一个用户操作或长任务只有一个 owner span 和一个终态；高频事件只做有界聚合。
- 日志、viewer、observer、磁盘或缓冲失败不得改变业务结果；生产代码不得自建日志通道。

## 前台局域网同步

- 支持 Windows、macOS 与 Android 前台、点对点、可信私有局域网；不提供后台或云端同步。首次用十分钟有效的配对二维码和双方
  六位码授权；双方完成本地保存与提交确认后才显示成功。稳定设备 ID 与策略进入 AppPersistence，二维码承载的
  预共享密钥在提交后作为逐设备长期密钥，进入独立的 AppPersistence 本地记录。Windows、macOS 与 Android
  均不为同步设备身份或配对密钥接入系统钥匙串、凭据存储、额外静态加密或签名 entitlement；这些值属于普通应用
  数据，但仍禁止进入日志、诊断、导出和设备间同步。更换到本地记录后不读取旧平台安全存储，历史配对需重新建立。
- 已配对会话必须认证加密；广播只包含设备 ID、标签和本次端口，IP 取收到的数据包且不得持久化。应用首帧与
  Runtime 就绪后启动前台宿主，两端在线时由稳定设备 ID 选出唯一自动发起方；广播只更新在线状态，上线边沿
  发起同步。桌面端/Android 组合固定由桌面端自动发起；桌面端每五分钟、Android 每十五分钟做一次
  持续在线校准且失败指数退避。任意一端可手动发起双向同步、仅拉取或仅推送，
  单次操作仍受双方持久方向与内容范围策略约束。Android 主动操作 Windows/macOS 时先发送逐设备密钥签名的 UDP
  唤醒，再由桌面端反向建立认证 TCP 会话；反向会话交换拉取/推送方向，按钮语义始终以发起端为准。
- Android 设备标签静默读取系统公开的厂商与型号，不申请运行时权限；发现广播中的新标签必须替换并持久化历史
  `localhost`/通用占位标签。连接或传输失败按服务启动、发现、唤醒、连接、认证、清单、计划、接收、发送、
  结果保存和书架刷新分阶段报告；UI 展示阶段、稳定错误码和有界技术原因，原始失败设备的 Debug 控制台保留完整
  异常与堆栈。反向连接失败须用已配对密钥签名回报阶段、错误码与有界技术原因，不能只让发起端等待超时。
- Android 只有系统确认已连接 Wi-Fi 时才允许同步、唤醒和在线广播；无 Wi-Fi 时保持低频状态探测，不发送 UDP。
  Windows/macOS 可使用 Wi-Fi 或带私有 IPv4 的有线局域网；macOS 还必须获得系统本地网络权限。桌面端在线广播间隔三秒，Android 六秒；Android
  开发书源变化合并四十五秒后再推送，桌面端开发变化可立即推动。对端会话内部失败必须在关闭加密连接前回报
  原始阶段、稳定错误码和有界原因，`disconnected` 不得覆盖正在执行的真实阶段。
- 每台设备独立控制自动同步、方向以及插件/书架范围；解除配对同时删除本机 metadata 与共享密钥。未配对的
  临时传输仍要求发送端保持页面并逐次核对确认码。
- 同步只包含书架身份/展示信息/进度和缺失或升级插件；不包含正文、设置、书签、删除操作或内部路径。
- 活动开发书源以成功激活内容的 SHA-256 指纹和本机单调修订号判新旧；相同指纹不重复传输，开发端可覆盖
  普通安装或旧开发副本。两端都是内容不同的活动开发项目时必须报告冲突并保留两端，构建失败继续保留旧代。
- 插件清单先交换不含制品字节的 offer；只有接收端计划明确选择某个缺失或升级插件后，发送端才按插件 ID
  生成该一个开发制品并发送真实大小与摘要。书架-only 会话不得查询或打包插件制品。
- 数据提交成功后只刷新现有书架与书源投影，不得销毁 Runtime 或首页 Provider；刷新期间及失败后保留之前可见
  的书架。传输成功但首页刷新失败是独立的部分成功终态，必须明确提示数据已提交并允许首页下拉重试。
- 协议、帧、manifest、chunk、artifact、批次和会话均须版本化且有界；超限、截断、未知版本和顺序错误
  必须稳定失败。

## 验证与平台证据

- 根 Flutter 编辑循环只检查拥有文件和直接测试，任务收尾执行一次仓库 analyze；全量格式和测试仅用于
  明确回归或发布。子项目使用最近 `AGENTS.md` 的验证入口。
- 页面、路由和跨层真实流程只用 Android `integration_test`，通过 Finder、语义和稳定 `Key` 交互；禁止
  坐标、桌面输入、`adb input` 和系统截图替代。
- 只有用户对当前任务明确授权后才使用已连接且 ready 的允许设备；Agent 不启动、唤醒、关闭或重置设备。
- 格式/静态、自动化、真实运行、平台/真机、发布和未执行项必须分别报告，不能互相替代。

## 文件、文档与版本治理

- 文件职责、IO、状态所有权、生命周期和真实 TODO 写在文件头；package 增量写最近 `AGENTS.md`；只有稳定
  跨模块规则进入本文件。禁止为单页面、阶段交付或测试快照新增文档。
- 手写源码达到 700 非空行且本次修改时开始按职责拆分，1000 行为硬上限；遗留基线只能下降。
- 根应用版本只在根 Flutter 生产代码、用户可见资源或发布配置变化后更新；文档、测试、工具、package、
  模板和独立数据源插件不升级根版本。
- `docs/` 只允许本核心规范、最小路由和入口；历史、实现快照、规划和重复说明由 Git 保存。
