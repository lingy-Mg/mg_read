# 音频与视频数据源契约

## 类型矩阵

| 维度 | 音频 | 视频 |
| --- | --- | --- |
| contentKind | `audio` | `video` |
| 目录 | 有序章节/曲目 | 扁平 episodes 加中性 `groups[]` |
| 播放模型 | 一个 collection 的队列 | `groupId + episodeId` 选择 |
| 宿主包 | `mg_read_audio_player` | `mg_read_video_player` |
| 不允许 | 视频分组/播放器状态 | 将 group 固定称为季或线路 |

目录中的 `items[]` 始终是稳定、完整的扁平清单。视频有 `groups[]` 时，每个 group 的 episodes 与 items
必须完全一一对应；group 只是一层来源结构，不表达跨来源的业务含义。

## 播放资源

`getContent` 对音频/视频返回 `text: null`、`pages: []` 和 `media`：

```ts
{
  url: ctx.resource.proxy({ kind: 'audio' | 'video' | 'hls', url, headers }),
  resourceType: 'audio' | 'video' | 'hls',
  resourcePolicy: 'sessionOnly' | 'refreshable',
  expiresAt: null | isoTime,
  mimeType: null | 'audio/mpeg',
  headers: { Referer: '...' }
}
```

`url` 是本地 Runtime proxy URL，不能是上游签名 URL。headers 仅保存在播放资源投影和 Runtime 数据面；不得
输出到日志、诊断、fixture、持久化书架、错误或页面。大文件和 Range 由 Runtime 流式转发，HLS 仅有小型
manifest 可读取重写，其变体、key 和 segment URI 继续通过 proxy。不得在插件 JS 中 fetch/arrayBuffer 整段媒体。

刷新不是凭 URL 字符串猜出的：来源能确认过期边界时才标记 `refreshable + expiresAt`。宿主在资源失效后重新
调用对应 `getContent`；无法确认时使用 `sessionOnly`，把播放失败作为可重试失败而非伪造有效期。

## 来源实现与证据

1. 先为 discover/search/detail/catalog/playback 写脱敏 fixture，成人或受限来源 fixture 只保留协议/选择器
   外壳，不保留标题、封面、正文或媒体 URL。
2. 音频至少断言章节序、proxy kind、Range/header 投影和 refreshable 的重新解析；禁止一次请求任意 5000 条
   曲目或在播放器首开时无上限并发解析。
3. 视频至少断言多个 fixture groups、每组多集、MacCMS player_data 的 JSON/常见 encode 分支、HLS proxy 与
   非 HLS 代理。线上只有单组时可保留该事实，但 fixture 仍覆盖多组解码。
4. live smoke 只报告状态/链路，不保存响应。浏览器 DOM、Windows WebView2、Android WebView 与真实播放须
   单独取证；遭遇访问控制时停在 interaction_required。
