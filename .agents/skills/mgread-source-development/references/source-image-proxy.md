# 来源专用图片代理

适用于封面或漫画页图需要来源自己的解密、条带重排、实时拼接等处理。先读目标来源入口、`packages/mg_read_source_api/index.d.ts`
的 `PluginResourceProxyRequest` / `PluginImageResourceResponse`、Runtime 的 `source-resource-coordinator.ts` 和直接测试。

## 链路

1. 数据源在发现、搜索、详情或正文中登记 `ctx.resource.proxy({ kind: 'image', url, handler, params })`，向 Flutter 返回
   Runtime loopback URL。`params` 仅携带解码所需的小型、可序列化参数，不携带图片主体或会话秘密。
2. Flutter 请求该 URL 时，Runtime 解码描述，核对 `kind=image` 和 handler 形式，在当前数据源的有界调用租约中调用
   可选导出 `getResource(request)`。来源不创建 listener，也不把自己的原始公网 URL 当作已解码结果返回。
3. 来源再次校验 URL 的协议、host、路径和参数；通过公开 `ctx.http.fetch` 获取单张图片，在有界内存中完成解码或拼接，
   返回 `{ bytes: Uint8Array, mimeType }`。Runtime 限制响应大小并通过同一个代理 URL 输出给 Flutter。

代理描述是可逆编码，不是认证令牌；不能把 Cookie、密钥或私有路径放进 `params`。来源处理器必须把来自代理 URL 的
所有字段当作不可信输入。读取时继承 Runtime 的取消信号和截止时间；来源应限制上游图片字节、像素数与输出大小。

普通图片继续使用 Runtime 直通资源代理；HLS、音频和视频继续由 Runtime 数据面流式处理。不要为单站点专用算法
增加通用 Runtime transform。测试至少覆盖原始图片到可解码输出的像素顺序、拒绝非法 host/参数、代理回调分发、
真实图片样本，以及 Flutter 实际请求代理 URL 的宿主链路。Node 回调测试不能替代 App 实际检查。
