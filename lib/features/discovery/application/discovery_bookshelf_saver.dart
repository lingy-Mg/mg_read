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
import 'package:mg_read/features/discovery/application/persisted_source_detail.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';

/// Application port for saving one typed discovery result to the local shelf.
abstract interface class DiscoveryBookshelfSaver {
  /// Saves a full detail from the detail page, or a bounded summary from a
  /// non-detail host. New UI entrypoints should always provide [detail].
  Future<void> save({required PluginSourceDescriptor source, PluginContentSummary? content, PluginContentDetail? detail});
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
  Future<void> save({required PluginSourceDescriptor source, PluginContentSummary? content, PluginContentDetail? detail}) async {
    final resolvedDetail = detail ?? _detailFromSummary(source, content);
    final summary = resolvedDetail.summary;
    final mutation = DiscoveryBookshelfMutation(
      BookshelfAddRequest(
        title: summary.title,
        author: summary.author,
        kind: switch (summary.contentKind) {
          PluginContentKind.novel => ContentKind.novel,
          PluginContentKind.manga => ContentKind.manga,
          PluginContentKind.audio => ContentKind.audio,
          PluginContentKind.video => ContentKind.video,
        },
        pluginId: source.id,
        pluginVersion: source.pluginVersion,
        remoteContentId: summary.id,
        coverUrl: summary.coverUrl,
        sourceName: resolvedDetail.sourceName.isEmpty ? source.displayName : resolvedDetail.sourceName,
        sourceUrl: resolvedDetail.catalogUrl ?? summary.url,
        description: summary.description,
        language: summary.language,
        accessCode: summary.access.code,
        wordCount: summary.wordCount,
        chapterCount: summary.chapterCount,
        publishedAt: summary.publishedAt,
        updatedAt: summary.updatedAt,
        statusLabel: _statusLabel(summary.status),
        latestChapterId: summary.latestChapter?.id,
        latestChapterTitle: summary.latestChapter?.title,
        latestChapterUrl: summary.latestChapter?.url,
        latestChapterUpdatedAt: summary.latestChapter?.updatedAt,
        categories: summary.categories,
        tags: summary.tags,
        attributes: <LibraryItemAttribute>[
          for (final attribute in summary.attributes)
            LibraryItemAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
        ],
        sourceDetail: encodePersistedSourceDetail(resolvedDetail),
        labels: <String>[...summary.categories, ...summary.tags, for (final attribute in summary.attributes) attribute.value],
      ),
    );
    if (await membership?.containsWhenReady(pluginId: mutation.request.pluginId, title: mutation.request.title) ?? false) {
      return;
    }
    onMutationStarted?.call(mutation);
    try {
      final item = await _library.addLibraryItem(mutation.request);
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

PluginContentDetail _detailFromSummary(PluginSourceDescriptor source, PluginContentSummary? content) {
  if (content == null) throw ArgumentError('Either detail or content must be provided.');
  return PluginContentDetail(
    pluginId: source.id,
    sourceName: source.displayName,
    summary: content,
    aliases: const <String>[],
    catalogUrl: content.url,
  );
}

final class _UnavailableDiscoveryBookshelfSaver implements DiscoveryBookshelfSaver {
  const _UnavailableDiscoveryBookshelfSaver();

  @override
  Future<void> save({required PluginSourceDescriptor source, PluginContentSummary? content, PluginContentDetail? detail}) =>
      Future<void>.error(StateError('Local bookshelf is unavailable.'));
}
