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

发现页的开发期阅读器联调可在未创建 `LibraryItem` 的前提下，用 Runtime Facade 的详情、目录和正文
构造一次 route-lifetime 的临时阅读会话。该会话的目录、正文、进度、书签和阅读设置只存在内存，
退出阅读器即丢弃；它不得写入任何 app SQLite、文件对象、Runtime 缓存或书架记录，也不能替代本
专题定义的正式入库流程。
