/// 发现与搜索结果的书架写入适配器。
///
/// 职责：
/// - 将数据源摘要完整转换为应用自有的书架展示缓存。
/// - 保持入架乐观投影、幂等写入和后台预取语义。
///
/// 注意：
/// - 书架提交成功不等待详情、目录或正文预取。
/// - 结构化属性必须保留键名，避免热度等字段在书架详情中丢失。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';

/// Application port for saving one typed discovery result to the local shelf.
abstract interface class DiscoveryBookshelfSaver {
  Future<void> save({required PluginSourceDescriptor source, required PluginContentSummary content});
}

/// One source-detail shelf request as observed by app composition.
///
/// The identifier only uses stable source identity, so no source payload or
/// user-visible data is needed to reconcile an optimistic local projection.
final class DiscoveryBookshelfMutation {
  const DiscoveryBookshelfMutation(this.request);

  final BookshelfAddRequest request;

  String get id => '${request.pluginId}:${request.remoteContentId}';
}

/// Main-app adapter that writes only through the public Content Library API.
final class ContentLibraryDiscoveryBookshelfSaver implements DiscoveryBookshelfSaver {
  const ContentLibraryDiscoveryBookshelfSaver(
    this._library, {
    this.onMutationStarted,
    this.onMutationCommitted,
    this.onMutationFailed,
    this.prefetcher,
    this.membership,
  });

  final ContentLibrary _library;
  final void Function(DiscoveryBookshelfMutation mutation)? onMutationStarted;
  final void Function(DiscoveryBookshelfMutation mutation, LibraryItem item)? onMutationCommitted;
  final void Function(DiscoveryBookshelfMutation mutation)? onMutationFailed;
  final ContentLibrarySourcePrefetcher? prefetcher;
  final BookshelfMembershipController? membership;

  @override
  Future<void> save({required PluginSourceDescriptor source, required PluginContentSummary content}) async {
    final mutation = DiscoveryBookshelfMutation(
      BookshelfAddRequest(
        title: content.title,
        author: content.author,
        kind: switch (content.contentKind) {
          PluginContentKind.novel => ContentKind.novel,
          PluginContentKind.manga => ContentKind.manga,
          PluginContentKind.audio => ContentKind.audio,
          PluginContentKind.video => ContentKind.video,
        },
        pluginId: source.id,
        pluginVersion: source.pluginVersion,
        remoteContentId: content.id,
        coverUrl: content.coverUrl,
        sourceName: source.displayName,
        sourceUrl: content.url,
        description: content.description,
        language: content.language,
        accessCode: content.access.code,
        wordCount: content.wordCount,
        chapterCount: content.chapterCount,
        publishedAt: content.publishedAt,
        updatedAt: content.updatedAt,
        statusLabel: _statusLabel(content.status),
        latestChapterId: content.latestChapter?.id,
        latestChapterTitle: content.latestChapter?.title,
        latestChapterUrl: content.latestChapter?.url,
        latestChapterUpdatedAt: content.latestChapter?.updatedAt,
        categories: content.categories,
        tags: content.tags,
        attributes: <LibraryItemAttribute>[
          for (final attribute in content.attributes)
            LibraryItemAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
        ],
        labels: <String>[...content.categories, ...content.tags, for (final attribute in content.attributes) attribute.value],
      ),
    );
    if (await membership?.containsWhenReady(pluginId: mutation.request.pluginId, title: mutation.request.title) ?? false) {
      return;
    }
    onMutationStarted?.call(mutation);
    try {
      final item = await _library.bookshelf.addFromSource(mutation.request);
      onMutationCommitted?.call(mutation, item);
      prefetcher?.start(item);
    } on Object {
      onMutationFailed?.call(mutation);
      rethrow;
    }
  }
}

String? _statusLabel(PluginContentStatus status) => switch (status) {
  PluginContentStatus.ongoing => '连载',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停更新',
  PluginContentStatus.unknown => null,
};

/// Test-only default: real app composition overrides this with Content Library.
final discoveryBookshelfSaverProvider = Provider<DiscoveryBookshelfSaver>((Ref ref) => const _UnavailableDiscoveryBookshelfSaver());

final class _UnavailableDiscoveryBookshelfSaver implements DiscoveryBookshelfSaver {
  const _UnavailableDiscoveryBookshelfSaver();

  @override
  Future<void> save({required PluginSourceDescriptor source, required PluginContentSummary content}) =>
      Future<void>.error(StateError('Local bookshelf is unavailable.'));
}
