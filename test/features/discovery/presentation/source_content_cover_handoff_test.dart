/// 搜索/发现详情到阅读器与播放器的封面交接测试。
///
/// 职责：
/// - 验证入口摘要的封面不会被无本地字节的 Runtime 详情覆盖。
/// - 覆盖小说、漫画、音频和视频四种出口回调。
///
/// 注意：
/// - 本测试只验证主应用路由数据，不启动真实阅读器或播放器。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

void main() {
  for (final kind in PluginContentKind.values) {
    testWidgets('${kind.code} receives the cover supplied by its search or discovery entry', (tester) async {
      List<int>? receivedCoverBytes;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(),
            home: _DetailEntryHost(kind: kind, onCoverReceived: (bytes) => receivedCoverBytes = bytes),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('source-detail-start-reading')));
      await tester.pumpAndSettle();

      expect(receivedCoverBytes, _onePixelPng);
    });
  }

  testWidgets('shelf detail keeps its visible cover through seed and Runtime replacement', (tester) async {
    List<int>? receivedCoverBytes;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: _DeferredDetailEntryHost(onCoverReceived: (bytes) => receivedCoverBytes = bytes),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-start-reading')));
    await tester.pumpAndSettle();

    expect(receivedCoverBytes, _onePixelPng);
  });
}

class _DetailEntryHost extends StatefulWidget {
  const _DetailEntryHost({required this.kind, required this.onCoverReceived});

  final PluginContentKind kind;
  final ValueChanged<List<int>?> onCoverReceived;

  @override
  State<_DetailEntryHost> createState() => _DetailEntryHostState();
}

class _DetailEntryHostState extends State<_DetailEntryHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _CoverDroppingGateway(widget.kind),
          pluginId: _pluginId,
          pluginVersion: '1.0.0',
          id: _contentId,
          initialContent: _summary(widget.kind, coverBytes: _onePixelPng, coverUrl: _coverUrl),
          onTextChapterRequested: widget.kind != PluginContentKind.novel
              ? null
              : ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async {
                  widget.onCoverReceived(entryCoverBytes);
                },
          onComicChapterRequested: widget.kind != PluginContentKind.manga
              ? null
              : ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async {
                  widget.onCoverReceived(entryCoverBytes);
                },
          onAudioChapterRequested: widget.kind != PluginContentKind.audio
              ? null
              : ({required detail, required firstCatalogPage, required chapter}) async {
                  widget.onCoverReceived(detail.summary.coverBytes);
                },
          onVideoEpisodeRequested: widget.kind != PluginContentKind.video
              ? null
              : ({required detail, required firstCatalogPage, required chapter}) async {
                  widget.onCoverReceived(detail.summary.coverBytes);
                },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _DeferredDetailEntryHost extends StatefulWidget {
  const _DeferredDetailEntryHost({required this.onCoverReceived});

  final ValueChanged<List<int>?> onCoverReceived;

  @override
  State<_DeferredDetailEntryHost> createState() => _DeferredDetailEntryHostState();
}

class _DeferredDetailEntryHostState extends State<_DeferredDetailEntryHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final initialDetail = PluginContentDetail(
        pluginId: _pluginId,
        sourceName: '测试来源',
        summary: _summary(PluginContentKind.video, coverBytes: null, coverUrl: null),
        aliases: const <String>[],
        catalogUrl: null,
      );
      unawaited(
        showDeferredSourceContentDetailSheet(
          context,
          seed: Future<SourceContentDetailSeed>.value(
            SourceContentDetailSeed(
              pluginId: _pluginId,
              pluginVersion: '1.0.0',
              id: _contentId,
              initialDetail: initialDetail,
              initialCatalog: _catalog,
            ),
          ),
          previewDetail: PluginContentDetail(
            pluginId: _pluginId,
            sourceName: '测试来源',
            summary: _summary(PluginContentKind.video, coverBytes: _onePixelPng, coverUrl: _coverUrl),
            aliases: const <String>[],
            catalogUrl: null,
          ),
          previewPluginVersion: '1.0.0',
          gateway: const _CoverDroppingGateway(PluginContentKind.video),
          shelfState: SourceDetailShelfState.alreadyAdded,
          onShelfAction: (_) async {},
          onStartReading: () async {},
          onVideoEpisodeRequested: ({required detail, required firstCatalogPage, required chapter}) async {
            widget.onCoverReceived(detail.summary.coverBytes);
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _CoverDroppingGateway implements SourceContentGateway {
  const _CoverDroppingGateway(this.kind);

  final PluginContentKind kind;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: '测试来源',
    summary: _summary(kind, coverBytes: null, coverUrl: null),
    aliases: const <String>[],
    catalogUrl: null,
  );

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => _catalog;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
}

const _pluginId = 'fixture-source';
const _contentId = 'content-1';
final _coverUrl = Uri.parse('https://covers.example/entry.png');
final _onePixelPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
final _catalog = PluginChaptersResult(
  pluginId: _pluginId,
  sourceName: '测试来源',
  items: <PluginChapterSummary>[
    PluginChapterSummary(
      id: 'chapter-1',
      title: '第一章',
      order: 0,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: const <PluginContentAttribute>[],
    ),
  ],
);

PluginContentSummary _summary(PluginContentKind kind, {required List<int>? coverBytes, required Uri? coverUrl}) => PluginContentSummary(
  id: _contentId,
  title: '测试内容',
  contentKind: kind,
  author: null,
  url: null,
  coverUrl: coverUrl,
  coverBytes: coverBytes,
  description: null,
  language: null,
  status: PluginContentStatus.unknown,
  access: PluginAccessKind.unknown,
  wordCount: null,
  chapterCount: 1,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);
