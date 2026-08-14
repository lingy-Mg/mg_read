# Content Library 数据对接说明

本文说明当前 `mg_read` 内已提交的 Content Library 基础能力如何保存和读取数据。它面向后续 Runtime adapter、书架/详情/阅读器功能的接入者；不要求页面、插件或 Runtime 直接接触 SQLite、文件路径或动态 JSON。

> 当前状态：底层存储和读取 API 已存在，但尚未接到现有 UI，也尚未提供应用启动时的 Riverpod provider。接入前须由应用组合根创建并持有唯一的 `ContentLibrary`，应用退出时调用 `close()`。

## 数据关系

```text
LibraryItem（书架中的一本书/漫画）
  └─ SourceBookBinding（一个插件来源；当前仅完成基础记录）
      └─ CatalogSnapshot（当前目录快照）
          └─ CatalogEntry（单章）
              └─ ChapterContent
                  ├─ NovelChapterContent：UTF-8 正文
                  └─ MangaChapterContent：有序 MangaPage 列表
```

`LibraryItemId`、`CatalogEntryId`、`ContentObjectId` 和 `ContentAssetId` 都是宿主生成的 opaque ID。标题和 URL 只是展示或资源信息，不能用作本地主键。

## 本地文件布局

```text
<dataRoot>/
  app_metadata.sqlite       # 书架、来源、目录、内容引用
  content.sqlite            # 小说正文和漫画章节 manifest
  files/content-assets/
    <libraryItemId>/        # 该漫画的所有本地图片
      <assetId>.asset
```

- 正文和 manifest 不进入 `app_metadata.sqlite`。
- 漫画图片不进入 SQLite 或 JSON。
- 图片当前不做 SHA-256 校验；丢失可由未来来源重新获取。
- 移除漫画 `LibraryItem` 会删除对应 `<libraryItemId>` 图片目录。

## 页面读取

页面只能依赖公开 barrel：

```dart
import 'package:mg_read/core/content_library/content_library.dart';
```

典型读取流程：

```dart
final Page<LibraryItem> shelf = await library.listLibrary(
  const LibraryQuery(limit: 50),
);

final Page<CatalogEntry> catalog = await library.listCatalog(
  item.id,
  const CatalogQuery(limit: 100),
);

final ReadableContent? content = await library.openContent(entry.id);
switch (content) {
  case NovelChapterContent(:final text):
    // 交给小说阅读器。
  case MangaChapterContent(:final pages):
    // 交给漫画阅读器；每页提供 pageId、顺序、SourceResource。
  case UnsupportedContent(:final kindCode):
    // 显示“当前版本不支持此内容类型”。
  case null:
    // 显示“内容尚未保存”。
}
```

分页必须使用返回的 `nextCursor` 继续请求，不能假定一次读出完整目录：

```dart
String? cursor;
do {
  final page = await library.listCatalog(
    item.id,
    CatalogQuery(after: cursor, limit: 100),
  );
  // 仅消费本页 page.items。
  cursor = page.nextCursor;
} while (cursor != null);
```

## Runtime / 导入写入

写入 DTO（`ContentLibraryIngest`、`IngestCatalogEntry`、`IngestMangaPage`）故意未从公开 barrel 导出。未来只能在 `lib/core/content_library/` 内的受控 adapter 使用它们，经过校验后调用：

1. `bookshelf.add`：创建或按来源 identity 去重书架项目。
2. `catalog.replaceSnapshot`：以 250 条为一批写入目录，完成后切换当前 snapshot。
3. `content.putNovel`：写入一章 UTF-8 文本，并把目录项指向该对象。
4. `content.putManga`：写入一章 manifest；每页有稳定 `pageId`、顺序和 `SourceResource`。
5. `FileObjectStore.commitBytes(mangaId, assetId, ...)`：保存已取得的漫画图片到该漫画目录。

页面、Runtime 或插件不得直接导入 `lib/core/content_library/src/`、`PersistenceRecordStore`、Drift、数据库路径，或读取/写入上述文件。

## 漫画资源策略

- `SourceResource.durable(url)`：普通可保存的 URL。
- `SourceResource.refreshable(url, expiresAtUtc)`：可保存但会过期，未来由来源刷新。
- `SourceResource.sessionOnly()`：不保存 URL；读取时 URL 为 `null`，需未来来源重新提供。

`MangaPage.downloadedAssetId` 代表本地图片对象 ID；当前文件层已能按漫画保存/删除图片，但“页与 assetId 的持久化关联”尚未完成，不应在 UI 中假定下载映射已可用。

## 删除语义

```dart
await library.bookshelf.remove(
  item.id,
  LibraryRemovalPolicy.removeFromShelfKeepContent,
);
```

当前行为：

- 小说：删除书架项目；正文、目录等内部残留暂不回收。
- 漫画：删除书架项目，并删除该漫画的图片文件夹；目录和 manifest 暂不回收。

`removeIncludingUnreferencedContent` 尚未实现与前一策略的差异，后续实现 GC 后才可用于“删除未引用正文/manifest”。

## 当前对接限制

- 书架多来源的完整查询、切换和 unavailable 状态尚未实现。
- UI、Reader、Runtime transport 均未接线；本说明不授权添加 WebSocket、HTTP 或 Runtime client。
- 目录旧快照、正文对象与 manifest 的自动回收尚未实现。
- 不做压力/容量/强杀恢复测试；当前测试只验证正常功能路径。
- `ContentLibrary.open()` 当前独立创建其 registry；和 Settings 共同启动前，应先补齐统一的 AppPersistence 组合根，确保同一 `app_metadata.sqlite` 只打开一次。

## 现有功能测试

`test/core/content_library/content_library_test.dart` 覆盖：

- 小说书架、目录、正文写入与重开读取；
- 漫画 session-only 页面不会保存 URL；
- 图片按漫画目录保存，移除漫画后整目录删除。
