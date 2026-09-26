# 原生来源公开边界

唯一初始化入口 `mg_source_init_v3` 的固定返回布局由 `../mg_read_native_runtime/abi/lib.rs` 定义。
新归档必须 `abi:3`；开发阶段直接替换旧版。没有 HostApi、invoke/cancel/release 或资源字节 ABI。
完整时序见 [实现契约](../mg_read_native_runtime/IMPLEMENTATION_CONTRACT.md)。

- 原生插件在一个共享 worker 内按需初始化，随后以 HTTP `{method,params}` 接受六个来源方法。
  Node 与原生保持相同内容语义、稳定 id/target/cursor/chapterId 和强类型 Facade；SDK 校验预算、能力和资源归属。
- manifest 可声明 novel/manga/audio/video；JSON 8 MiB，小说单章 1 MiB，目录/漫画页最多 5000。参考 Alice 只声明小说。
- 插件内部 `{$resource:{kind,url,headers?}}` 由 SDK 投影为 `/v1/source-resource/<base64url-json>`。
  payload 与 Node 一样包含完整描述，额外 engine=native；缓存存 descriptor，不存动态端口。无内存令牌表或闲置过期。
- Base64 可逆，不保证上游头的秘密性。媒体公开 headers 为空，但 payload 本身可能携带上游头，禁止把其当成加密。
- `SourceResourceResolveInvocation` 统一判断来源归属，在下载前取得当前端口；不直接相信旧 URL 的端口。
  原生内容结果必须匹配经过认证的当前初始化端点。禁用/卸载来源不能解析；远端直连 HTTP URL 原样返回。
- SDK 提供异步内容调用、断连取消、普通资源和 HLS 重写。源级变换仍由插件实现；不把 Node handler、WebView 或 DRM 隐式引入原生。
- 来源为可信 DLL/SO，缓存路径校验防止误用，不构成恶意代码沙箱。worker 退出才是动态库卸载边界。

参考来源：`../../plugins/sources/aisishuwu-native/`。协议、Facade、真实 App/播放器分别验收。
