import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Host-owned intent to open a selected source text chapter in a reader.
typedef SourceTextChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
    });

/// Opens a host-owned detail/catalog surface backed by typed Runtime calls.
Future<void> showSourceContentDetailSheet(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  SourceTextChapterRequested? onTextChapterRequested,
}) {
  final detailFuture = _loadDetail(gateway, pluginId, id);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.88,
      child: SafeArea(
        top: false,
        child: FutureBuilder<_SourceDetailBundle>(
          future: detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: Semantics(
                  label: '正在加载内容详情与目录',
                  child: const CircularProgressIndicator(),
                ),
              );
            }
            if (snapshot.hasError) {
              return _SheetFailure(
                error: AppError.fromUnknown(snapshot.error!),
              );
            }
            return _SourceDetailView(
              bundle: snapshot.requireData,
              gateway: gateway,
              onTextChapterRequested: onTextChapterRequested,
            );
          },
        ),
      ),
    ),
  );
}

Future<_SourceDetailBundle> _loadDetail(
  SourceContentGateway gateway,
  String pluginId,
  String id,
) async {
  final values = await Future.wait<Object>(<Future<Object>>[
    gateway.getDetail(pluginId: pluginId, id: id),
    gateway.getChapters(pluginId: pluginId, id: id),
  ]);
  return _SourceDetailBundle(
    detail: values[0] as PluginContentDetail,
    chapters: values[1] as PluginChaptersResult,
  );
}

final class _SourceDetailBundle {
  const _SourceDetailBundle({required this.detail, required this.chapters});

  final PluginContentDetail detail;
  final PluginChaptersResult chapters;
}

class _SourceDetailView extends StatelessWidget {
  const _SourceDetailView({
    required this.bundle,
    required this.gateway,
    required this.onTextChapterRequested,
  });

  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final SourceTextChapterRequested? onTextChapterRequested;

  @override
  Widget build(BuildContext context) {
    final detail = bundle.detail;
    final content = detail.summary;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.comfortable,
        0,
        AppSpacing.comfortable,
        AppSpacing.page,
      ),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(content.title, style: theme.textTheme.titleLarge),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        Text(
          '${detail.sourceName} · ${_contentKindLabel(content.contentKind)}',
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
        Text(
          '来源标识：${content.id}',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
        const SizedBox(height: AppSpacing.regular),
        Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: <Widget>[
            Chip(label: Text('状态：${_statusLabel(content.status)}')),
            Chip(label: Text('访问：${_accessLabel(content.access)}')),
            if (content.author != null)
              Chip(label: Text('作者：${content.author}')),
            if (content.wordCount != null)
              Chip(label: Text('字数：${content.wordCount}')),
            if (content.chapterCount != null)
              Chip(label: Text('章节：${content.chapterCount}')),
            if (content.language != null)
              Chip(label: Text('语言：${content.language}')),
          ],
        ),
        if (detail.aliases.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text('别名：${detail.aliases.join('、')}'),
        ],
        if (content.description != null) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text(content.description!),
        ],
        if (content.updatedAt != null) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text('更新时间：${_formatDateTime(content.updatedAt!)}'),
        ],
        if (content.publishedAt != null)
          Text('发布时间：${_formatDateTime(content.publishedAt!)}'),
        if (content.latestChapter != null) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text('最新章节：${content.latestChapter!.title}'),
          if (content.latestChapter!.id != null)
            Text('章节标识：${content.latestChapter!.id}'),
          if (content.latestChapter!.updatedAt != null)
            Text('章节更新：${_formatDateTime(content.latestChapter!.updatedAt!)}'),
          if (content.latestChapter!.url != null)
            _SheetUrl(label: '最新章节 URL', value: content.latestChapter!.url!),
        ],
        if (content.categories.isNotEmpty ||
            content.tags.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Wrap(
            spacing: AppSpacing.compact,
            runSpacing: AppSpacing.unit,
            children: <Widget>[
              for (final value in content.categories) Chip(label: Text(value)),
              for (final value in content.tags) Chip(label: Text(value)),
            ],
          ),
        ],
        if (content.attributes.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          for (final attribute in content.attributes)
            Text('${attribute.label}：${attribute.value}'),
        ],
        if (content.url != null)
          _SheetUrl(label: '内容 URL', value: content.url!),
        if (content.coverUrl != null)
          _SheetUrl(label: '封面 URL', value: content.coverUrl!),
        if (detail.catalogUrl != null)
          _SheetUrl(label: '目录 URL', value: detail.catalogUrl!),
        const SizedBox(height: AppSpacing.section),
        Row(
          children: <Widget>[
            Expanded(child: Text('目录', style: theme.textTheme.titleMedium)),
            Text(
              bundle.chapters.totalCount == null
                  ? '本页 ${bundle.chapters.items.length} 章'
                  : '共 ${bundle.chapters.totalCount} 章',
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.mutedText,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.compact),
        if (bundle.chapters.items.isEmpty)
          Text('插件明确返回了空目录。', style: TextStyle(color: tokens.mutedText))
        else
          for (final chapter in bundle.chapters.items)
            ListTile(
              key: ValueKey<String>('source-chapter-${chapter.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(chapter.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_chapterSubtitle(chapter)),
                  if (chapter.url != null)
                    SelectableText(chapter.url.toString()),
                  for (final attribute in chapter.attributes)
                    Text('${attribute.label}：${attribute.value}'),
                ],
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                if (content.contentKind == PluginContentKind.novel) {
                  unawaited(
                    _openTextChapter(
                      context,
                      gateway: gateway,
                      detail: detail,
                      firstCatalogPage: bundle.chapters,
                      chapter: chapter,
                      onTextChapterRequested: onTextChapterRequested,
                    ),
                  );
                } else {
                  unawaited(
                    _showChapterContent(
                      context,
                      gateway: gateway,
                      pluginId: detail.pluginId,
                      id: content.id,
                      chapter: chapter,
                    ),
                  );
                }
              },
            ),
      ],
    );
  }
}

/// Closes the detail sheet before asking the host application to open a reader.
Future<void> _openTextChapter(
  BuildContext context, {
  required SourceContentGateway gateway,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  required SourceTextChapterRequested? onTextChapterRequested,
}) async {
  final callback = onTextChapterRequested;
  if (callback == null) {
    await _showChapterContent(
      context,
      gateway: gateway,
      pluginId: detail.pluginId,
      id: detail.summary.id,
      chapter: chapter,
    );
    return;
  }
  Navigator.of(context).pop();
  await callback(
    detail: detail,
    firstCatalogPage: firstCatalogPage,
    chapter: chapter,
  );
}

Future<void> _showChapterContent(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  required PluginChapterSummary chapter,
}) {
  final contentFuture = gateway.getContent(
    pluginId: pluginId,
    id: id,
    chapterId: chapter.id,
  );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: SafeArea(
        top: false,
        child: FutureBuilder<PluginChapterContent>(
          future: contentFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _SheetFailure(
                error: AppError.fromUnknown(snapshot.error!),
              );
            }
            final content = snapshot.requireData;
            return ListView(
              key: const Key('source-chapter-content-sheet'),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.comfortable,
                0,
                AppSpacing.comfortable,
                AppSpacing.page,
              ),
              children: <Widget>[
                Text(
                  content.title ?? chapter.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text('章节标识：${content.chapterId}'),
                if (content.updatedAt != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.compact),
                  Text('更新时间：${_formatDateTime(content.updatedAt!)}'),
                ],
                const SizedBox(height: AppSpacing.regular),
                if (content.contentKind == PluginContentKind.novel)
                  if (content.text!.isEmpty)
                    Text(
                      '插件明确返回了空正文。',
                      style: TextStyle(
                        color: AppThemeTokens.of(context).mutedText,
                      ),
                    )
                  else
                    SelectableText(content.text!)
                else
                  for (final page in content.pages)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Text('${page.index + 1}'),
                      title: SelectableText(page.url.toString()),
                      subtitle: Text(_mangaPageSubtitle(page)),
                    ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _SheetUrl extends StatelessWidget {
  const _SheetUrl({required this.label, required this.value});

  final String label;
  final Uri value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.regular),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpacing.unit),
          SelectableText(
            value.toString(),
            style: TextStyle(color: AppThemeTokens.of(context).accent),
          ),
        ],
      ),
    );
  }
}

class _SheetFailure extends StatelessWidget {
  const _SheetFailure({required this.error});

  final AppError error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.section),
        child: Text(
          '无法加载内容（${error.code.wireValue}）',
          key: const Key('source-content-sheet-failure'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _chapterSubtitle(PluginChapterSummary chapter) {
  final values = <String>[
    chapter.id,
    '#${chapter.order}',
    if (chapter.volumeTitle != null) chapter.volumeTitle!,
    if (chapter.wordCount != null) '${chapter.wordCount} 字',
    if (chapter.updatedAt != null) _formatDateTime(chapter.updatedAt!),
    if (chapter.isLocked != null) chapter.isLocked! ? '已锁定' : '可阅读',
  ];
  return values.join(' · ');
}

String _mangaPageSubtitle(PluginMangaPage page) {
  final values = <String>[
    page.id,
    if (page.mimeType != null) page.mimeType!,
    if (page.width != null && page.height != null)
      '${page.width} × ${page.height}',
  ];
  return values.join(' · ');
}

String _contentKindLabel(PluginContentKind value) => switch (value) {
  PluginContentKind.novel => '小说',
  PluginContentKind.manga => '漫画',
};

String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停更新',
  PluginContentStatus.unknown => '未知',
};

String _accessLabel(PluginAccessKind value) => switch (value) {
  PluginAccessKind.free => '免费',
  PluginAccessKind.paid => '付费',
  PluginAccessKind.mixed => '部分付费',
  PluginAccessKind.unknown => '未知',
};

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
