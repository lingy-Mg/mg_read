# 音频与视频来源

## 事实入口

- Runtime 内容类型与校验：`plugin-content-types.ts`、`plugin-content-validation.ts`
- 媒体代理：`packages/mg_read_node_runtime/src/media-resource-proxy.ts`
- Flutter 宿主：`packages/mg_read_audio_player/lib/mg_read_audio_player.dart`、
  `packages/mg_read_video_player/lib/mg_read_video_player.dart`
- 目标来源入口、直接 contract/fixture 测试和一个同媒体类型真实来源

## 类型与所有权

| 维度 | 音频 | 视频 |
| --- | --- | --- |
| contentKind | `audio` | `video` |
| 目录 | 有序章节/曲目 | 扁平 episodes 和中性 `groups[]` |
| 宿主选择 | 队列与当前章节 | `groupId + episodeId` |

音频和视频分别实现、分别验证，不抽成通用媒体模型。视频 group 可表示季、线路或版本，Runtime/UI 不写死语义；
存在 groups 时，本次已加载的 episode 与扁平 items 一一对应。宿主中间投影不能丢失 groups，仅在来源确实无分组时使用
扁平兼容。

视频源可选导出 `deferredGroups = true`。新 Node Runtime 仅向声明该能力的源传入
`supportsDeferredGroups: true`；未协商时仍返回旧的完整目录。初次返回默认分组的完整章节，其他分组可用
`deferred: true, episodes: []` 表示待加载；缺省/false 仍表示完整非空分组。`getChapters` 可选 `groupId`
请求目标分组全部章节，返回完整分组索引和该组元数据；可选 `refresh: true` 绕过来源目录缓存。
不使用占位章节、不做组内分页、不提前解析视频资源。稳定分组 ID 不依赖排序；旧的小目录行为须有回归。
宿主缓存共享于详情/播放器且有容量和过期边界，失败不缓存、并发单飞、刷新拒绝旧结果；续播先加载保存的分组。
正式自检和 testkit 显式遍历延迟分组，普通 UI/书架预取不得自动补全。

## 播放资源

- `getContent` 返回 `text: null`、空 pages 和一个 Runtime proxy media。
- `audio`、`video`、`hls` 是不同资源类型。大文件与 Range 由 Runtime 流式转发；HLS manifest、variant、key
  和 segment URI 都留在代理数据面。
- 插件不整体读取媒体、不 `arrayBuffer()`、不 Base64 化或缓存媒体主体。
- 只有来源能确认过期边界时使用 `refreshable + expiresAt`；否则用 `sessionOnly`。失效后由宿主重新调用
  `getContent`。

按 [content-validation-matrix.md](content-validation-matrix.md)分别验证音频、视频/HLS 和封面。来源离线测试与
`verify` 必须通过；请求链变化再运行 live smoke，播放器宿主变化另跑相邻 package 测试。真实播放、Windows
WebView2 和 Android WebView 分开取证。
