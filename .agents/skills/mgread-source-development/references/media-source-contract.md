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
存在 groups 时，全部 episode 与扁平 items 一一对应。宿主中间投影不能丢失 groups，仅在来源确实无分组时使用
扁平兼容。

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
