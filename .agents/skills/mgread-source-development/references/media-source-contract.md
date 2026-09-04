# 音频与视频数据源

## 事实入口

- Runtime 内容类型与校验：`plugin-content-types.ts`、`plugin-content-validation.ts`
- 媒体代理：`packages/mg_read_node_runtime/src/media-resource-proxy.ts`
- Flutter 宿主：`packages/mg_read_audio_player/lib/mg_read_audio_player.dart`、
  `packages/mg_read_video_player/lib/mg_read_video_player.dart`
- 真实来源入口文件头和直接 contract/fixture 测试

## 类型与所有权

| 维度 | 音频 | 视频 |
| --- | --- | --- |
| contentKind | `audio` | `video` |
| 目录 | 有序章节/曲目 | 扁平 episodes 和中性 `groups[]` |
| 宿主选择 | 队列与当前章节 | `groupId + episodeId` |

音频和视频分别实现、分别验证，不抽成通用媒体源。视频 group 可表示季、线路或版本，Runtime/UI 不写死语义；
存在 groups 时，全部 episode 必须与扁平 items 一一对应。详情与播放器都按 `groups[]` 展示并切换分组；宿主
中间投影不得只复制 `items` 而丢失 `groups`，仅在来源确实没有分组时才用扁平 items 兼容。

## 播放资源

- `getContent` 返回 `text: null`、空 pages 和一个 Runtime proxy media。
- `audio`、`video` 和 `hls` 是不同资源类型。大文件与 Range 由 Runtime 流式转发；HLS manifest、
  variant、key 和 segment URI 均保持在代理数据面。
- 插件 JS 不整体读取媒体、arrayBuffer、Base64 化或缓存媒体主体。
- 只有来源能确认过期边界时才使用 `refreshable + expiresAt`；否则使用 `sessionOnly`。宿主在失效后重新
  调用 `getContent`，资源有效期由来源和宿主共同决定。

## 最小验证

- Fixture 覆盖 discover/search/detail/catalog/playback，由来源测试定义所需结构。
- 音频覆盖章节顺序、proxy kind、Range/header 和刷新重取；视频覆盖多 group、多 episode、player-data 分支、
  HLS 与非 HLS 代理。
- 运行来源离线测试和 `verify`；请求链变化再运行明确存在的 live smoke。播放器宿主变化另跑相邻 package
  测试；真实播放、Windows WebView2 和 Android WebView 分开取证。
