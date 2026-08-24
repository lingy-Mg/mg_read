# 20 内容资料库（Content Library）

本专题落实 ADR-0100。`mg_read` 是书架、目录、正文与本地漫画资产的权威持有者；Runtime 只在未来经强类型 adapter 提交已验证的数据，绝不取得数据库路径、连接或文件绝对路径。

```text
AppPersistence
  app_metadata.sqlite  LibraryItem / Binding / Snapshot / Entry / 引用
  content.sqlite       不可变小说 UTF-8 正文、漫画章节 manifest
  files/content-assets 不可猜测 ID 的漫画图片字节
```

三者没有跨库原子事务：先写入并校验 object/file，再以 metadata revision CAS 指向新对象；故障后已提交 metadata 为准。无引用对象留给有界 maintenance/GC；引用缺失投影为 damaged。目录刷新写 pending snapshot（每批 100–500 条），只通过一次 CAS 切换 active snapshot；查询采用 `(orderKey, recordId)` keyset cursor，不用 offset 或全量载入。

本交付只做功能验证，不包含目录或正文压力/容量测试。不得在交互路径 VACUUM；轻量备份只含 metadata，完整正文备份须采用未来流式/在线备份。

`ContentLibrary` 向 feature/reader 提供异步强类型仓储；内部 PluginSourceData（pluginId、版本、dataVersion、opaque JSON）不从公开 barrel 导出。普通 JSON 禁止正文、Base64、二进制与绝对路径。首版仅 novel/manga；未知类型只读。漫画文件按漫画 LibraryItemId 分目录，移除漫画时删除整个目录。

书架小说加入后由共享预取器通过 Runtime Facade 单次取得经解码的完整目录，再以稳定远端章节
ID 原子切换一次本地 catalog snapshot；Reader 若与预取并发则等待同一任务，预取失败后可同步
重试一次。已有完整 catalog 不因重开阅读器被覆盖；远端详情章节数大于本地时，视为开发期半目录
并重新拉取完整目录。章节正文按需请求：先查 `ContentLibrary`，缺失时才由 typed gateway 获取、
校验为小说文本并提交正文对象。Reader 的“已下载/未下载/失败”状态只能由该 catalog entry 的正文
引用与当前请求状态生成，不能用页面会话或固定 UI 文案伪造。阅读进度使用语义锚点，并累计 host
观察到的前台阅读秒数；旧进度记录未带时长时按零兼容读取。

发现页的开发期阅读器联调可在未创建 `LibraryItem` 的前提下，用 Runtime Facade 的详情、目录和正文
构造一次 route-lifetime 的临时阅读会话。该会话的目录、正文、进度、书签和阅读设置只存在内存，
退出阅读器即丢弃；它不得写入任何 app SQLite、文件对象、Runtime 缓存或书架记录，也不能替代本
专题定义的正式入库流程。
