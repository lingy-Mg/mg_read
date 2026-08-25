# 全局封面持久化规范

本文是搜索、发现、详情和书架封面的共同实现规范。封面属于可再生成的展示资源，必须由主应用统一缓存；不能由某个页面或组件自行决定“每次进入都重新加载”。

## 适用范围

以下所有来源封面都使用同一套能力：

- 搜索结果和搜索结果分组；
- 发现页的榜单、推荐、分类、轮播、列表及后续新增组件；
- 来源详情页和详情内的相关推荐；
- 书架以及从书架进入详情的内容。

## 所有权与键

- 持久化所有权属于主应用 `ContentLibrary.covers`，底层文件由 `AppPersistence` 的文件对象存储管理。
- Runtime、插件私有 cache、SQLite 记录、HTTP/HTML/JSON/base64 字段都不是封面缓存的存储位置。
- 封面键由 `pluginId + pluginVersion + remoteContentId + coverUrl` 组成，再以 SHA-256 作为文件目录名。URL 变化必须产生新键，不能覆盖旧键的语义身份。
- 书架、搜索、发现和详情必须使用相同的来源身份与 URL 生成键；来源版本未知时统一使用 `unknown`。

## 读取与写入流程

共享封面读取器负责：

1. 先通过 `ContentLibrary.covers.read` 读取本地 bytes；命中后不得再次请求网络。
2. 未命中时才请求来源 URL；成功后通过 `ContentLibrary.covers.save` 写入，再把 bytes 交给封面组件。
3. 读取、下载、解码或写入失败只影响封面，必须回退占位图，不能让搜索、发现、详情或书架失败。
4. 单个封面最多 5 MiB；全局封面缓存最多 100 MiB，按最近访问时间淘汰最旧文件。缓存是离线可读的，不设置会破坏离线体验的硬过期。
5. 来源主动刷新并返回新 URL 时，按新键重新获取；不得在 Widget 中偷偷刷新。

书架旧的 item-owned 封面可以作为迁移回退，命中后应补写到全局键，以避免升级后重复下载。

## 异步展示与新增组件硬规则

- 内容网关和书架概览只返回主体字段、已知 `coverBytes`（若有）及封面来源身份，绝不等待封面读取、下载或解码完成。
- `LibraryBookCover`、`DiscoveryBookCover` 及同类展示组件通过共享的只读 Provider 消费已解析的 `coverBytes`、加载态或确定性的占位图。Provider 以来源身份去重，并在所有订阅者释放后自动释放。
- Widget 的 `build` 以及展示组件不得调用 `Image.network`、`NetworkImage`、`HttpClient`、Runtime、Persistence 或 Provider 写入。
- 新增发现组件只要展示 `PluginContentSummary`，必须复用共享封面组件并传入 `content.id`、`content.coverUrl` 与当前书源身份；不得直接读取 URL 绘制网络图片。
- 新增内容模型或新增 Runtime projection 时，必须同步确认其能提供封面来源身份；不能再在 application gateway 中补一次同步 hydration。
- 加载中必须立即显示加载状态；缺图、坏图和网络失败只显示占位图，且不改变主体内容的加载或错误语义。
- 新增组件必须至少补一条本地命中、未命中后写入、失败占位的测试证据；涉及导航的组件同时遵守发现页返回规范。

## Code review 清单

提交前确认：

- [ ] 新入口经过 `SourceContentGateway` 或同等 feature data adapter，并携带封面来源身份；
- [ ] 已使用 `CoverKey` 和 `ContentLibrary.covers`；
- [ ] 首次成功加载后有持久化，下一次加载可离线命中；
- [ ] Widget 没有网络加载和持久化副作用，且加载态不阻塞主体显示；
- [ ] 缺图、坏图、网络失败都显示占位图且不阻断主内容；
- [ ] 测试覆盖命中、写入复用和失败回退；
- [ ] 若新增的是发现组件，已同步更新本规范并复查所有新增封面入口。
