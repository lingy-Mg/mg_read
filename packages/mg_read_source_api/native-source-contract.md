# 原生来源公开边界

原生入口 `mg_source_get_api_v2` 和五个函数的唯一布局位于 `../mg_read_native_runtime/abi/lib.rs`。
新归档必须 `abi:2`，开发阶段直接替换 v1；不提供 HostApi、通用 HTTP/storage 回调或资源字节 ABI。
生命周期和完整调用约束见 [实现契约](../mg_read_native_runtime/IMPLEMENTATION_CONTRACT.md)。

- `{method,request}`、六个内容方法及来源定义的稳定 id/target/cursor/chapterId 沿用 Node 的内容语义。
  原生宿主检查预算、能力、结果身份和资源归属，补充 pluginId/sourceName；相同 Dart Facade 完成最终强类型解码。
- manifest 可声明 novel/manga/audio/video；总 JSON 8 MiB，小说单章 1 MiB，目录/漫画页最多 5000。正文不截断。
  参考 Alice 仍只声明小说。WebView、浏览器档案及 Node 私有 handler 不属于原生 v2 能力。
- 静态链接 SDK 的 `{$resource:{kind,url,headers?}}` 由插件内部解析成自己的动态端口 HTTP URL。
  缓存存 descriptor，不能持久化端口、资源令牌或已投影 URL。该标记是 SDK 便捷表示，不是宿主资源回调。
- 原生媒体遵守相同 media/resourceType/resourcePolicy/expiresAt 结构，公开 headers 必须为空；上游凭据保留在
  插件服务内部。漫画不能声明 durable：本地 URL 随 worker 或闲置令牌到期失效。
- SDK 提供普通图片/音频/视频流和 HLS 主/子清单、分片、密钥、初始化片段改写。来源专属变换由插件自行实现；
  当前 SDK 明确拒绝 resourceTransform，不能把 Node 的 handler 名称直接交给原生引擎。
- Flutter 的统一 URL 解析器只识别路由；原生 URL 还必须匹配经过认证的当前 worker 登记的插件、端口和世代。
  普通 HTTP URL 不能冒充插件资源。Node 保留原有资源 URL 和代理实现。
- 来源为可信原生代码。私有缓存目录和 SDK 的路径校验防止误用，不构成恶意 DLL/SO 的权限沙箱。

参考来源：`../../plugins/sources/aisishuwu-native/`。SDK HTTP 测试、Facade 测试、真实 App/播放器分别验收。
