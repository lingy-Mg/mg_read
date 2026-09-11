/// 数据源漫画章节到 Content Library 清单的共享投影。
///
/// 职责：
/// - 让入架预取与书架阅读使用同一套章节、页面和资源策略校验。
/// - 保留仅会话 URL，持久层只接收允许落盘的资源元数据。
///
/// 注意：
/// - 图片字节不在这里下载；其网络与持久缓存生命周期由阅读数据源持有。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';

final class SourceMangaChapterProjection {
  const SourceMangaChapterProjection({required this.descriptors, required this.sessionOnlyUrls});

  final List<MangaPageDescriptor> descriptors;
  final Map<String, Uri> sessionOnlyUrls;
}

SourceMangaChapterProjection projectSourceMangaChapter(PluginChapterContent content, String chapterId) {
  if (content.contentKind != PluginContentKind.manga) throw StateError('Source chapter is not manga.');
  if (content.chapterId != chapterId) throw StateError('Source returned a different manga chapter.');
  if (content.pages.isEmpty) throw StateError('Source manga manifest is empty.');
  final ids = <String>{};
  final indexes = <int>{};
  final updatedVersion = content.updatedAt?.toUtc().millisecondsSinceEpoch ?? 1;
  final version = updatedVersion > 0 ? updatedVersion : 1;
  final sorted = content.pages.toList(growable: false)..sort((left, right) => left.index.compareTo(right.index));
  final descriptors = <MangaPageDescriptor>[];
  final sessionOnlyUrls = <String, Uri>{};
  for (final page in sorted) {
    if (page.id.isEmpty || page.index < 0 || !ids.add(page.id) || !indexes.add(page.index)) {
      throw StateError('Source manga manifest contains duplicate or invalid pages.');
    }
    final resource = switch (page.resourcePolicy) {
      PluginMangaPageResourcePolicy.sessionOnly => SourceResource.sessionOnly(),
      PluginMangaPageResourcePolicy.refreshable => SourceResource.refreshable(
        page.url,
        page.expiresAt ?? (throw StateError('Refreshable manga page is missing expiresAt.')),
      ),
      PluginMangaPageResourcePolicy.durable => SourceResource.durable(page.url),
    };
    if (page.resourcePolicy == PluginMangaPageResourcePolicy.sessionOnly) {
      sessionOnlyUrls[page.id] = page.url;
    }
    descriptors.add(
      MangaPageDescriptor(
        pageId: page.id,
        order: page.index,
        resource: resource,
        mimeType: page.mimeType ?? 'image/unknown',
        width: page.width,
        height: page.height,
        contentVersion: version,
      ),
    );
  }
  return SourceMangaChapterProjection(
    descriptors: List<MangaPageDescriptor>.unmodifiable(descriptors),
    sessionOnlyUrls: Map<String, Uri>.unmodifiable(sessionOnlyUrls),
  );
}
