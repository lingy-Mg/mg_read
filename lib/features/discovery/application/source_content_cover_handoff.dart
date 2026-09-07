/// 数据源内容封面交接。
///
/// 职责：
/// - 在搜索、发现或书架摘要切换到 Runtime 详情时保留已解析的封面。
/// - 让小说、漫画、音频和视频共用同一个主应用交接规则。
///
/// 注意：
/// - `coverBytes` 是宿主本地数据，不会出现在 Runtime wire 返回中。
/// - 只能用同一内容 ID 的上游摘要补缺；不覆盖详情已给出的封面数据。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Preserves host-local cover data while a Runtime detail refresh replaces the
/// rest of the immutable source summary.
PluginContentDetail preserveSourceContentCover({
  required PluginContentDetail detail,
  PluginContentSummary? fallbackSummary,
  List<int>? resolvedCoverBytes,
}) {
  final summary = detail.summary;
  final fallback = fallbackSummary?.id == summary.id ? fallbackSummary : null;
  final currentBytes = _nonEmpty(summary.coverBytes);
  final handedOffBytes = _nonEmpty(resolvedCoverBytes) ?? _nonEmpty(fallback?.coverBytes);
  final coverBytes = currentBytes ?? handedOffBytes;
  final coverUrl = summary.coverUrl ?? fallback?.coverUrl;
  final usesFallbackIdentity = summary.coverUrl == null && fallback?.coverUrl != null;
  final coverOrientation = usesFallbackIdentity ? fallback!.coverOrientation : summary.coverOrientation;

  if (currentBytes == coverBytes && summary.coverUrl == coverUrl && summary.coverOrientation == coverOrientation) {
    return detail;
  }
  return PluginContentDetail(
    pluginId: detail.pluginId,
    sourceName: detail.sourceName,
    aliases: detail.aliases,
    catalogUrl: detail.catalogUrl,
    summary: PluginContentSummary(
      id: summary.id,
      title: summary.title,
      contentKind: summary.contentKind,
      coverOrientation: coverOrientation,
      author: summary.author,
      url: summary.url,
      coverUrl: coverUrl,
      coverBytes: coverBytes,
      description: summary.description,
      language: summary.language,
      status: summary.status,
      access: summary.access,
      wordCount: summary.wordCount,
      chapterCount: summary.chapterCount,
      publishedAt: summary.publishedAt,
      updatedAt: summary.updatedAt,
      latestChapter: summary.latestChapter,
      categories: summary.categories,
      tags: summary.tags,
      attributes: summary.attributes,
    ),
  );
}

List<int>? _nonEmpty(List<int>? bytes) => bytes == null || bytes.isEmpty ? null : bytes;
