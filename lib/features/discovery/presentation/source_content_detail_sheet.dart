import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';

typedef SourceTextChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
    });

typedef SourceExternalUrlLauncher = Future<bool> Function(Uri url);

Future<void> showSourceContentDetailSheet(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  SourceTextChapterRequested? onTextChapterRequested,
  SourceExternalUrlLauncher? onExternalUrlRequested,
}) {
  final detailFuture = _loadDetail(gateway, pluginId, id);
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _SourceDetailScreen(
        detailFuture: detailFuture,
        gateway: gateway,
        onTextChapterRequested: onTextChapterRequested,
        onExternalUrlRequested: onExternalUrlRequested ?? _launchSystemBrowser,
      ),
    ),
  );
}

Future<bool> _launchSystemBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

Future<_SourceDetailBundle> _loadDetail(
  SourceContentGateway gateway,
  String pluginId,
  String id,
) async {
  final detail = await gateway.getDetail(pluginId: pluginId, id: id);
  final chapters = await gateway.getChapters(
    pluginId: pluginId,
    id: id,
    pageSize: 20,
  );
  return _SourceDetailBundle(detail: detail, chapters: chapters);
}

final class _SourceDetailBundle {
  const _SourceDetailBundle({required this.detail, required this.chapters});
  final PluginContentDetail detail;
  final PluginChaptersResult chapters;
}

class _SourceDetailScreen extends StatelessWidget {
  const _SourceDetailScreen({
    required this.detailFuture,
    required this.gateway,
    required this.onTextChapterRequested,
    required this.onExternalUrlRequested,
  });
  final Future<_SourceDetailBundle> detailFuture;
  final SourceContentGateway gateway;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: FutureBuilder<_SourceDetailBundle>(
        future: detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: Semantics(
                label: '正在加载内容详情与目录',
                child: CircularProgressIndicator(),
              ),
            );
          }
          if (snapshot.hasError) {
            return _DetailFailure(error: AppError.fromUnknown(snapshot.error!));
          }
          return _SourceDetailView(
            bundle: snapshot.requireData,
            gateway: gateway,
            onTextChapterRequested: onTextChapterRequested,
            onExternalUrlRequested: onExternalUrlRequested,
          );
        },
      ),
    ),
  );
}

class _SourceDetailView extends StatefulWidget {
  const _SourceDetailView({
    required this.bundle,
    required this.gateway,
    required this.onTextChapterRequested,
    required this.onExternalUrlRequested,
  });
  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  @override
  State<_SourceDetailView> createState() => _SourceDetailViewState();
}

class _SourceDetailViewState extends State<_SourceDetailView> {
  late final List<PluginChapterSummary> _chapters;
  late String? _nextCursor;
  late int? _totalCount;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _chapters = List<PluginChapterSummary>.of(widget.bundle.chapters.items);
    _nextCursor = widget.bundle.chapters.nextCursor;
    _totalCount = widget.bundle.chapters.totalCount;
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final next = await widget.gateway.getChapters(
        pluginId: widget.bundle.detail.pluginId,
        id: widget.bundle.detail.summary.id,
        cursor: cursor,
        pageSize: 20,
      );
      if (!mounted) return;
      final seen = _chapters.map((chapter) => chapter.id).toSet();
      setState(() {
        _chapters.addAll(next.items.where((chapter) => seen.add(chapter.id)));
        _nextCursor = next.nextCursor;
        _totalCount = next.totalCount ?? _totalCount;
        _isLoadingMore = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法加载更多章节，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => _SourceDetailBody(
    bundle: _SourceDetailBundle(
      detail: widget.bundle.detail,
      chapters: PluginChaptersResult(
        pluginId: widget.bundle.chapters.pluginId,
        sourceName: widget.bundle.chapters.sourceName,
        items: _chapters,
        nextCursor: _nextCursor,
        totalCount: _totalCount,
      ),
    ),
    gateway: widget.gateway,
    onTextChapterRequested: widget.onTextChapterRequested,
    onExternalUrlRequested: widget.onExternalUrlRequested,
    isLoadingMore: _isLoadingMore,
    onLoadMore: _nextCursor == null ? null : _loadMore,
  );
}

class _SourceDetailBody extends StatelessWidget {
  const _SourceDetailBody({
    required this.bundle,
    required this.gateway,
    required this.onTextChapterRequested,
    required this.onExternalUrlRequested,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceExternalUrlLauncher onExternalUrlRequested;
  final bool isLoadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final detail = bundle.detail;
    final content = detail.summary;
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final firstChapter = bundle.chapters.items.isEmpty
        ? null
        : bundle.chapters.items.first;
    final labels = <String>{
      ...content.categories,
      ...content.tags,
    }.toList(growable: false);
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, AppSpacing.page),
      children: <Widget>[
        _DetailHeader(sourceUrl: content.url, onOpenUrl: _openUrl),
        const SizedBox(height: AppSpacing.regular),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              key: const Key('source-detail-open-cover-url'),
              onTap: content.coverUrl == null
                  ? null
                  : () => unawaited(_openUrl(context, content.coverUrl)),
              borderRadius: AppRadii.discoveryCover,
              child: DiscoveryBookCover(
                key: const Key('source-detail-cover'),
                title: content.title,
                coverUrl: content.coverUrl,
                variant: _coverVariant(content.id),
                width: 112,
                height: 158,
              ),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    content.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1.18,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.person_outline_rounded,
                        size: 20,
                        color: tokens.mutedText,
                      ),
                      const SizedBox(width: AppSpacing.unit),
                      Expanded(
                        child: Text(
                          content.author ?? '作者未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: tokens.mutedText,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (labels.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.regular),
                    Wrap(
                      spacing: AppSpacing.compact,
                      runSpacing: AppSpacing.unit,
                      children: labels
                          .map((value) => _DetailTag(label: value))
                          .toList(growable: false),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.regular),
                  Divider(color: tokens.divider),
                  _DetailStats(content: content),
                  Divider(color: tokens.divider),
                  _ExternalRow(
                    key: const Key('source-detail-source-url'),
                    label: '来源频道：${detail.sourceName}',
                    url: content.url,
                    onOpenUrl: _openUrl,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.regular),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('source-detail-add-shelf'),
                onPressed: () => ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('书架保存功能尚未接入此书源。'))),
                icon: const Icon(Icons.library_add_outlined),
                label: const Text('加入书架'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  foregroundColor: tokens.accent,
                  side: BorderSide(color: tokens.accent),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: FilledButton(
                key: const Key('source-detail-start-reading'),
                onPressed: firstChapter == null
                    ? null
                    : () => unawaited(
                        _openTextChapter(
                          context,
                          gateway: gateway,
                          detail: detail,
                          firstCatalogPage: bundle.chapters,
                          chapter: firstChapter,
                          onTextChapterRequested: onTextChapterRequested,
                        ),
                      ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: tokens.accent,
                ),
                child: const Text('开始阅读'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider),
        const SizedBox(height: AppSpacing.comfortable),
        Text(
          '简介',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.compact),
        Text(
          content.description ?? '该书源未提供简介。',
          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
        ),
        if (_displayAttributes(content.attributes).isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Wrap(
            spacing: AppSpacing.compact,
            runSpacing: AppSpacing.unit,
            children: _displayAttributes(content.attributes)
                .map(
                  (value) => _DetailTag(label: '${value.label}：${value.value}'),
                )
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider),
        if (content.latestChapter != null)
          _ExternalRow(
            key: const Key('source-detail-latest-chapter-url'),
            title: '最新章节',
            label: content.latestChapter!.title,
            subtitle: content.latestChapter!.updatedAt == null
                ? null
                : _formatDateTime(content.latestChapter!.updatedAt!),
            url: content.latestChapter!.url,
            onOpenUrl: _openUrl,
          ),
        _ExternalRow(
          key: const Key('source-detail-catalog-url'),
          title: '阅读来源',
          label: '当前来源：${detail.sourceName}',
          url: detail.catalogUrl ?? content.url,
          onOpenUrl: _openUrl,
        ),
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider),
        Text(
          '目录',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          bundle.chapters.totalCount == null
              ? '本页 ${bundle.chapters.items.length} 章'
              : '共 ${bundle.chapters.totalCount} 章',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
        for (final chapter in bundle.chapters.items)
          _ChapterRow(
            chapter: chapter,
            onRead: () => unawaited(
              _openTextChapter(
                context,
                gateway: gateway,
                detail: detail,
                firstCatalogPage: bundle.chapters,
                chapter: chapter,
                onTextChapterRequested: onTextChapterRequested,
              ),
            ),
            onOpenUrl: _openUrl,
          ),
        if (onLoadMore != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.regular),
            child: OutlinedButton(
              key: const Key('source-detail-load-more-chapters'),
              onPressed: isLoadingMore ? null : onLoadMore,
              child: isLoadingMore
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加载更多章节'),
            ),
          ),
      ],
    );
  }

  Future<void> _openUrl(BuildContext context, Uri? url) async {
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) return;
    final launched = await onExternalUrlRequested(url);
    if (!context.mounted || launched) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开该链接。')));
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.sourceUrl, required this.onOpenUrl});
  final Uri? sourceUrl;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: <Widget>[
        IconButton(
          key: const Key('source-detail-back'),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        const Spacer(),
        IconButton(
          key: const Key('source-detail-open-source-url'),
          tooltip: '在浏览器打开来源',
          onPressed: sourceUrl == null
              ? null
              : () => unawaited(onOpenUrl(context, sourceUrl)),
          icon: const Icon(Icons.ios_share_rounded),
        ),
        IconButton(
          tooltip: '更多',
          onPressed: () {},
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ],
    ),
  );
}

class _DetailStats extends StatelessWidget {
  const _DetailStats({required this.content});
  final PluginContentSummary content;

  @override
  Widget build(BuildContext context) {
    final heat = _attributeValue(content.attributes, 'heat');
    final favorites = _attributeValue(content.attributes, 'favorites');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.comfortable),
      child: Row(
        children: <Widget>[
          _Stat(
            value: heat ?? _legacyWordCount(content.wordCount),
            label: heat == null
                ? '字数'
                : favorites == null
                ? '热度'
                : '热度 · 收藏 $favorites',
          ),
          _Stat(value: _wordCount(content.wordCount), label: '字数'),
          _Stat(
            value: _chapterCount(content.chapterCount),
            label: '章节 · ${_statusLabel(content.status)}',
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: <Widget>[
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.unit),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppThemeTokens.of(context).mutedText,
          ),
        ),
      ],
    ),
  );
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppThemeTokens.of(context).mutedSurface,
      borderRadius: AppRadii.pill,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.compact,
        vertical: AppSpacing.unit,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppThemeTokens.of(context).mutedText,
        ),
      ),
    ),
  );
}

class _ExternalRow extends StatelessWidget {
  const _ExternalRow({
    required this.label,
    required this.url,
    required this.onOpenUrl,
    this.title,
    this.subtitle,
    super.key,
  });
  final String? title;
  final String label;
  final String? subtitle;
  final Uri? url;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: url == null ? null : () => unawaited(onOpenUrl(context, url)),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Text(
                    title!,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppThemeTokens.of(context).mutedText,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: AppThemeTokens.of(context).mutedText,
          ),
        ],
      ),
    ),
  );
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.onRead,
    required this.onOpenUrl,
  });
  final PluginChapterSummary chapter;
  final VoidCallback onRead;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('source-chapter-${chapter.id}'),
    contentPadding: EdgeInsets.zero,
    title: Text(chapter.title),
    subtitle: Text(_chapterSubtitle(chapter)),
    trailing: chapter.url == null
        ? const Icon(Icons.chevron_right_rounded)
        : IconButton(
            key: ValueKey<String>('source-chapter-url-${chapter.id}'),
            tooltip: '在浏览器打开章节',
            onPressed: () => unawaited(onOpenUrl(context, chapter.url)),
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
    onTap: onRead,
  );
}

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
      heightFactor: .9,
      child: FutureBuilder<PluginChapterContent>(
        future: contentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DetailFailure(error: AppError.fromUnknown(snapshot.error!));
          }
          final content = snapshot.requireData;
          return ListView(
            key: const Key('source-chapter-content-sheet'),
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            children: <Widget>[
              Text(
                content.title ?? chapter.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.regular),
              if (content.contentKind == PluginContentKind.novel)
                SelectableText(content.text ?? '')
              else
                for (final page in content.pages)
                  _ExternalRow(
                    label: '第 ${page.index + 1} 页',
                    subtitle: _mangaPageSubtitle(page),
                    url: page.url,
                    onOpenUrl: (context, url) async {
                      if (url != null) await _launchSystemBrowser(url);
                    },
                  ),
            ],
          );
        },
      ),
    ),
  );
}

class _DetailFailure extends StatelessWidget {
  const _DetailFailure({required this.error});
  final AppError error;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      '无法加载内容（${error.code.wireValue}）',
      key: const Key('source-content-sheet-failure'),
    ),
  );
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum %
      DiscoveryCoverVariant.values.length];
}

String _wordCount(int? value) {
  if (value == null) return '—';
  if (value < 10000) return '$value字';
  final count = value / 10000;
  final digits = value % 10000 == 0 ? 0 : 2;
  return '${count.toStringAsFixed(digits)}万';
}

String _legacyWordCount(int? value) => value == null ? '—' : '字数：$value';

String _chapterCount(int? value) => value == null ? '—' : '$value';
String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停',
  PluginContentStatus.unknown => '未知',
};
String _chapterSubtitle(PluginChapterSummary chapter) => <String>[
  if (chapter.wordCount != null) '${chapter.wordCount} 字',
  if (chapter.updatedAt != null) _formatDateTime(chapter.updatedAt!),
  if (chapter.isLocked != null) chapter.isLocked! ? '已锁定' : '可阅读',
].join(' · ');
String _mangaPageSubtitle(PluginMangaPage page) => <String>[
  if (page.mimeType != null) page.mimeType!,
  if (page.width != null && page.height != null)
    '${page.width} × ${page.height}',
].join(' · ');

String? _attributeValue(
  Iterable<PluginContentAttribute> attributes,
  String key,
) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

Iterable<PluginContentAttribute> _displayAttributes(
  Iterable<PluginContentAttribute> attributes,
) => attributes.where(
  (attribute) => attribute.key != 'heat' && attribute.key != 'favorites',
);

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
