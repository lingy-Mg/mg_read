# 按内容类型验证

## 共同规则

自动检测先完成 `discover.root -> discover.target.* -> discover.append.* -> search -> detail -> catalog`，确认
稳定 ID、`contentKind`、目录完整有序且 ID 唯一，再按类型选择样本。target 和 continuation 都必须有界，
但不得找到第一个有内容的子列表就停止。搜索词从当前发现标题或建议派生，并找回同一稳定 ID；固定 ID
只允许作为无法自动发现时的显式诊断输入，不能成为默认通过路径。

封面、漫画页图、音频、视频/HLS 是独立资源组，报告必须分别给出 `passed/failed/notRegistered/notTested`。
一个可达封面不能让媒体通过，一条可播媒体也不能证明漫画页图或所有封面有效。所有远程探测都有候选数、
字节数和时间上限；读取足以识别格式的前缀后立即取消，不下载完整媒体或整章图片。

适用资源组由返回内容决定：任一摘要/详情给出封面时封面组适用；漫画 pages 使漫画图片组适用；音频和视频的
media 组始终适用。严格验证只有在内容链路与全部适用组通过时才通过；适用组为 `unverified/notTested` 时必须
报告为部分验证，不能沿用 CLI 的整体 `passed` 标签。

## 封面

将封面拆为 `discover.root`、每个已抽样 `discover.target`、`search` 和 `detail` 表面。每个非空内容表面都记录
内容数、封面 URL 数、成功登记数和有界探测结果；某个表面封面全部失效时，不得被另一表面的可达封面掩盖。

验证来源登记的真实上游 URL、kind、Referer/Accept 等 headers。通过条件是成功响应、图片 MIME、非空前缀且
文件签名与声明格式相容；有解码器时再验证正尺寸。分别记录 `404/403`、挑战页、错误 HTML、空对象和格式伪装，
不能只信扩展名或 `Content-Type`。若 CDN 以 `.png`/`image/png` 返回 JPEG/WebP，先判断站点是否提供有证据的格式
转换参数；普通代理否则记录为上游声明/字节不一致。需要来源专用图片解码时按
[source-image-proxy.md](source-image-proxy.md)验证真实解码输出。内容表面有项但未提供封面时记为
“未登记”而不是“已通过”。

## 小说与图书

自动脚本对小说采用图书链路，而不是资源链路：

- 优先选择未锁定、可公开读取的章节；对长目录只抽取去重后的首/中/末可读章节，不顺序抓取全书正文。
- 目录验证完整性、顺序、唯一 chapterId、标题和锁定语义；全部锁定时报告需要权限/无可读样本，不误判为空源。
- 正文必须是非空文本，`contentKind=novel`、chapterId 回传一致，且不能是 HTML 页面、挑战页、JSON 错误或
  导航壳。报告字符数和样本位置，不输出或持久化完整正文。
- 搜索标题可能含书名号、卷标、作者后缀或超长文本时，生成少量有界候选查询；仍以找回同一稳定 ID 为通过，
  不能只接受搜索首项。
- 适配连载与大目录时保持请求有界；首章可读、目录尾部可定位和中间章节可读分别提供证据。

## 漫画与写真

选择首/中/末可读章节；每章验证 pages 非空、page id/index 唯一有序、URL 经 proxy 登记。至少从两个不同章节
及各自不同页位选择有界图片样本（当实际可读章节/页数足够时），验证图片 MIME、签名和非空前缀；不能只探测封面
或只证明 pages 数组非空。
动态页面只在必须执行脚本时使用最小 WebView，并同时保留解析 fixture。

## 音频与音乐

验证详情、曲目/章节顺序、锁定语义、扁平 items 与 groups 对应、当前曲目标识和 `media.resourceType=audio`；每个
实际 group/线路至少验证一个样本。对实际媒体登记验证 headers、Range 行为、音频 MIME 或可接受的 octet-stream、
非空媒体前缀；直播首块从帧中间开始时可在有界窗口内确认连续有效帧，不下载完整音频。若地址带签名或会话期限，
稳定 ID 排除临时 token/sign/livekey，刷新后重新调用 `getContent`，并区分 `sessionOnly` 与有证据支持的
`refreshable + expiresAt`。封面仍按独立封面组验证。

## 视频

验证详情、扁平 episodes 与 `groups[]` 一一对应、`groupId + episodeId` 可稳定回传，且当前选集返回
`media.resourceType=video|hls`。线路标题从真实 tab/group 读取，不能把外层“选择播放源”容器当作线路；每个实际
group/线路至少验证一个样本，任一适用线路 404/错误页面都使视频组失败。直链视频使用有界 Range/前缀探测，接受
来源契约允许的 `206` 或可流式 `200`；检查视频 MIME、octet-stream 与容器签名的一致性，不下载整片。

HLS 至少验证主/媒体 playlist 是文本且以 `#EXTM3U` 开始，URI 能按基址解析；按需有界探测一个 variant、key
或 segment，保持 headers 和取消语义。真实 App CLI 还要对首/中/末及每个实际线路的代表样本执行
`playback.video`：静音打开生产 Runtime URL，等待视频表面首帧、playing 和 position 前进，并报告打开异常、流错误、
Runtime/代理不可用或首帧超时。解析出播放地址、playlist/segment 可达或封面通过都不等于 App 真实可播。

## 自动化实现要求

`mg_read_source_testkit` 应按 detail/content 的 `contentKind` 分派上述策略，并在报告中保留各资源组结果、样本
位置和稳定失败码。公共助手只提供有界抽样、格式识别和报告，不硬编码某个来源选择器、标题、章节数或固定内容。

当前 CLI 若只能证明“至少一个已登记资源可达”，任务还必须用来源 live 测试补齐未独立验证的资源组；不得把
聚合 `resourceStatus=reachable` 解读为封面、漫画图片、音频和视频全部通过。修改 testkit 时运行其离线自测、
小说/漫画/音频/视频各一个健康代表来源、故意失败 fixture 和全源继续执行行为。
