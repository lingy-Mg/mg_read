import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';
import 'package:mg_read/features/plugins/application/source_verification_catalog.dart';

void main() {
  test('cancels an in-flight Runtime request and ignores its late result', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final token = SourceVerificationCancellationToken();
    final gateway = _VerificationGateway(
      chapterCount: 5,
      onDiscover: () {
        entered.complete();
        return gate.future;
      },
    );
    final pending = SourceVerificationEngine(gateway).run(cancellationToken: token);
    await entered.future;
    expect(gateway.activeCancellation!.isCancelled, isFalse);
    token.cancel();
    final report = await pending.timeout(const Duration(seconds: 1));
    expect(gateway.activeCancellation!.isCancelled, isTrue);
    expect(report.cancelled, isTrue);
    expect(report.toJson()['status'], 'cancelled');
    expect(report.sources.single.status, SourceVerificationResultStatus.cancelled);
    expect(report.sources.single.stages.last.code, 'cancelled');
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.searchCalls, 0);
    expect(gateway.contentChapterIds, isEmpty);
  });

  test('cancelling during source loading prevents any source request', () async {
    final gate = Completer<void>();
    final gateway = _VerificationGateway(chapterCount: 5, onList: () => gate.future);
    final token = SourceVerificationCancellationToken();
    final pending = SourceVerificationEngine(gateway).run(cancellationToken: token);
    token.cancel();
    final report = await pending;
    expect(report.cancelled, isTrue);
    expect(report.sources, isEmpty);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.discoverCalls, 0);
  });

  test('stage timeout cancels its Runtime scope before continuing', () async {
    final gate = Completer<void>();
    final gateway = _VerificationGateway(chapterCount: 5, onDiscover: () => gate.future);
    final report = await SourceVerificationEngine(gateway, stageTimeout: const Duration(milliseconds: 20)).run();
    expect(report.cancelled, isFalse);
    expect(report.sources.single.failure?.code, 'timeout');
    expect(gateway.activeCancellation!.isCancelled, isTrue);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(gateway.searchCalls, 0);
  });

  test('cancellation between sources preserves completed results without claiming success', () async {
    final token = SourceVerificationCancellationToken();
    final gateway = _VerificationGateway(chapterCount: 5, sourceCount: 2);
    final snapshots = <SourceVerificationProgress>[];
    final report = await SourceVerificationEngine(gateway).run(
      cancellationToken: token,
      onProgress: (progress) {
        snapshots.add(progress);
        if (progress.completedSources.isNotEmpty) token.cancel();
      },
    );
    expect(report.totalSources, 2);
    expect(report.passedCount, 1);
    expect(report.cancelled, isTrue);
    expect(report.isSuccessful, isFalse);
    expect(gateway.discoverCalls, 1);
    expect(snapshots.first.completedSources, isEmpty);
    expect(snapshots.last.completedSources, hasLength(1));
    expect(snapshots.any((p) => p.stages.any((s) => s.stage == 'search')), isTrue);
  });

  test('cancelling a stalled resource closes the client and stops probing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>();
    var requests = 0;
    server.listen((request) {
      requests++;
      if (!entered.isCompleted) entered.complete();
    });
    try {
      final token = SourceVerificationCancellationToken();
      final gateway = _VerificationGateway(chapterCount: 5, coverUrl: Uri.parse('http://127.0.0.1:${server.port}/cover'));
      final pending = SourceVerificationEngine(gateway).run(cancellationToken: token);
      await entered.future;
      token.cancel();
      final report = await pending.timeout(const Duration(seconds: 1));
      expect(report.sources.single.stages.last.stage, 'resource.cover');
      expect(report.cancelled, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, 1);
    } finally {
      await server.close(force: true);
    }
  });

  test('late deferred group response cannot schedule the next group after cancellation', () async {
    final gateway = _DeferredGateway();
    final token = SourceVerificationCancellationToken();
    final pending = loadVerificationCatalog(gateway, 'source', 'book', cancellationToken: token);
    final assertion = expectLater(pending, throwsA(isA<SourceVerificationRunException>()));
    await gateway.entered.future;
    token.cancel();
    gateway.firstGroup.complete(
      PluginChaptersResult(
        pluginId: 'source',
        sourceName: 'Source',
        items: const [],
        groups: [PluginMediaGroup(id: 'first', title: 'First', order: 0, episodes: const [])],
      ),
    );
    await assertion;
    expect(gateway.calls, ['first']);
  });

  test('runs the production gateway chain and samples first middle and last content', () async {
    final gateway = _VerificationGateway(chapterCount: 5);
    final report = await SourceVerificationEngine(gateway).run(pluginId: _VerificationGateway.pluginId);

    expect(report.isSuccessful, isTrue);
    expect(report.toJson()['platform'], Platform.isMacOS ? 'macos' : 'windows');
    expect(gateway.contentChapterIds, <String>['chapter:0', 'chapter:2', 'chapter:4']);
    final source = report.sources.single;
    expect(source.status, SourceVerificationResultStatus.passed);
    expect(source.stages.map((stage) => stage.stage), <String>[
      'runtime',
      'discover',
      'search',
      'detail',
      'chapters',
      'content.first',
      'content.middle',
      'content.last',
      'resource.cover',
      'resource.content',
    ]);
    expect(source.stages.where((stage) => stage.stage == 'resource.cover').single.status, SourceVerificationStageStatus.skipped);
  });

  test('reports a Runtime-visible truncated catalog with a stable stage and code', () async {
    final report = await SourceVerificationEngine(_VerificationGateway(chapterCount: 6)).run(pluginId: _VerificationGateway.pluginId);

    expect(report.isSuccessful, isFalse);
    expect(report.failedCount, 1);
    expect(report.sources.single.failure?.stage, 'chapters');
    expect(report.sources.single.failure?.code, 'chapters_truncated');
    expect(report.sources.single.failure?.summary, <String, Object?>{'expected': 6, 'actual': 5});
  });

  test('accepts a WebP cover whose server reports application/octet-stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(const <int>[0x52, 0x49, 0x46, 0x46, 0x04, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]);
      await request.response.close();
    });
    try {
      final coverUrl = Uri.parse('http://${server.address.address}:${server.port}/cover.webp');
      final report = await SourceVerificationEngine(
        _VerificationGateway(chapterCount: 5, coverUrl: coverUrl),
      ).run(pluginId: _VerificationGateway.pluginId);

      expect(report.isSuccessful, isTrue);
      final coverStage = report.sources.single.stages.where((stage) => stage.stage == 'resource.cover').single;
      expect(coverStage.status, SourceVerificationStageStatus.passed);
    } finally {
      await server.close(force: true);
    }
  });

  test('emits full decoded source values through the explicit debug trace', () async {
    final traces = <SourceVerificationDebugRecord>[];
    await SourceVerificationEngine(_VerificationGateway(chapterCount: 5)).run(pluginId: _VerificationGateway.pluginId, onDebug: traces.add);

    final search = traces.singleWhere((trace) => trace.event == 'stage_response' && trace.stage == 'search');
    final searchItems = search.data!['items']! as List<Object?>;
    expect((searchItems.single as Map<String, Object?>)['title'], 'Fixture');

    final content = traces.singleWhere((trace) => trace.event == 'stage_response' && trace.stage == 'content.first');
    expect(content.data!['text'], 'fixture body');
  });

  test('uses the App playback probe for video lines and records first-frame evidence', () async {
    final server = await _startMediaServer();
    final probe = _VideoPlaybackProbe(passed: true);
    try {
      final report = await SourceVerificationEngine(
        _VideoVerificationGateway(_serverUri(server)),
      ).run(pluginId: _VideoVerificationGateway.pluginId, videoPlaybackProbe: probe);

      expect(report.isSuccessful, isTrue);
      expect(probe.calls, 3);
      final stage = report.sources.single.stages.singleWhere((stage) => stage.stage == 'playback.video');
      expect(stage.status, SourceVerificationStageStatus.passed);
      expect(stage.summary['tested'], 3);
      expect(stage.summary['failed'], 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('reports playback timeout separately from a reachable video resource', () async {
    final server = await _startMediaServer();
    final probe = _VideoPlaybackProbe(passed: false);
    try {
      final report = await SourceVerificationEngine(
        _VideoVerificationGateway(_serverUri(server)),
      ).run(pluginId: _VideoVerificationGateway.pluginId, videoPlaybackProbe: probe);

      expect(report.isSuccessful, isFalse);
      final failure = report.sources.single.failure!;
      expect(failure.stage, 'playback.video');
      expect(failure.code, 'video_playback_failed');
      final samples = failure.summary['samples']! as List<Object?>;
      expect(samples, hasLength(3));
      expect((samples.first! as Map<String, Object?>)['code'], 'video_first_frame_timeout');
    } finally {
      await server.close(force: true);
    }
  });
}

Future<HttpServer> _startMediaServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType.binary;
    request.response.add(const <int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]);
    await request.response.close();
  });
  return server;
}

Uri _serverUri(HttpServer server) => Uri.parse('http://${server.address.address}:${server.port}/video');

final class _VideoPlaybackProbe implements SourceVerificationVideoPlaybackProbe {
  _VideoPlaybackProbe({required this.passed});

  final bool passed;
  int calls = 0;

  @override
  Future<SourceVerificationVideoPlaybackProbeResult> probe(SourceVerificationVideoPlaybackRequest request) async {
    calls += 1;
    return SourceVerificationVideoPlaybackProbeResult(
      passed: passed,
      code: passed ? 'video_playback_ready' : 'video_first_frame_timeout',
      elapsed: const Duration(milliseconds: 25),
      firstFrameReady: passed,
      playing: passed,
      buffering: !passed,
      position: passed ? const Duration(milliseconds: 500) : Duration.zero,
      duration: const Duration(minutes: 1),
      bufferedPosition: passed ? const Duration(seconds: 5) : Duration.zero,
      errorMessage: passed ? null : 'The first frame did not arrive.',
    );
  }
}

final class _VideoVerificationGateway implements SourceContentGateway {
  _VideoVerificationGateway(this.mediaUrl);

  static const pluginId = 'org.mgread.video-fixture';
  final Uri mediaUrl;

  PluginContentSummary get summary => PluginContentSummary(
    id: 'video:fixture',
    title: 'Video Fixture',
    contentKind: PluginContentKind.video,
    author: null,
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: 3,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );

  List<PluginChapterSummary> get episodes => List<PluginChapterSummary>.generate(
    3,
    (index) => PluginChapterSummary(
      id: 'episode:$index',
      title: 'Episode $index',
      order: index,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: const <PluginContentAttribute>[],
    ),
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => <PluginSourceDescriptor>[
    PluginSourceDescriptor(
      id: pluginId,
      displayName: 'Video Fixture Source',
      pluginVersion: '1.0.0',
      contentKinds: const <PluginContentKind>[PluginContentKind.video],
    ),
  ];

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => PluginDiscoveryDocumentResult(
    pluginId: pluginId,
    sourceName: 'Video Fixture Source',
    document: PluginDiscoveryDocument(
      components: <PluginDiscoveryComponent>[
        PluginDiscoveryContentCollectionComponent(
          id: 'video-collection',
          layout: PluginDiscoveryContentLayout.list,
          items: <PluginDiscoveryContentItem>[PluginDiscoveryContentItem(content: summary, rank: null, metric: null, recommendation: null)],
          continuation: null,
        ),
      ],
    ),
  );

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async =>
      PluginSearchResult(
        pluginId: pluginId,
        sourceName: 'Video Fixture Source',
        items: <PluginContentSummary>[summary],
        nextCursor: null,
        totalCount: 1,
      );

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by verification engine.');

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: 'Video Fixture Source',
    summary: summary,
    aliases: const <String>[],
    catalogUrl: null,
  );

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    final values = episodes;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: 'Video Fixture Source',
      items: values,
      groups: <PluginMediaGroup>[
        PluginMediaGroup(id: 'line:1', title: 'Line 1', order: 0, episodes: values.take(2).toList(growable: false)),
        PluginMediaGroup(id: 'line:2', title: 'Line 2', order: 1, episodes: values.skip(2).toList(growable: false)),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      PluginChapterContent(
        pluginId: pluginId,
        sourceName: 'Video Fixture Source',
        contentKind: PluginContentKind.video,
        chapterId: chapterId,
        title: null,
        updatedAt: null,
        text: null,
        pages: const <PluginMangaPage>[],
        media: PluginMediaResource(
          url: mediaUrl,
          resourceType: PluginMediaResourceType.video,
          resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
          expiresAt: null,
          mimeType: 'video/mp4',
          headers: const <String, String>{},
        ),
      );
}

final class _VerificationGateway implements SourceContentGateway, CancellableSourceContentGateway {
  _VerificationGateway({required this.chapterCount, this.coverUrl, this.onDiscover, this.onList, this.sourceCount = 1});
  final Future<void> Function()? onDiscover;
  final Future<void> Function()? onList;
  final int sourceCount;
  int discoverCalls = 0;
  int searchCalls = 0;
  PluginInvocationCancellation? activeCancellation;

  @override
  Future<T> runCancellable<T>(PluginInvocationCancellation cancellation, Future<T> Function() request) {
    activeCancellation = cancellation;
    return request();
  }

  static const pluginId = 'org.mgread.fixture';
  final int chapterCount;
  final Uri? coverUrl;
  final List<String> contentChapterIds = <String>[];

  PluginContentSummary get summary => PluginContentSummary(
    id: 'novel:fixture',
    title: 'Fixture',
    contentKind: PluginContentKind.novel,
    author: null,
    url: null,
    coverUrl: coverUrl,
    description: null,
    language: 'zh',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    await onList?.call();
    return <PluginSourceDescriptor>[
      for (var i = 0; i < sourceCount; i++)
        PluginSourceDescriptor(
          id: sourceCount == 1 ? pluginId : '$pluginId.$i',
          displayName: 'Fixture Source',
          pluginVersion: '1.0.0',
          contentKinds: const <PluginContentKind>[PluginContentKind.novel],
        ),
    ];
  }

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    discoverCalls++;
    await onDiscover?.call();
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: 'Fixture Source',
      document: PluginDiscoveryDocument(
        components: <PluginDiscoveryComponent>[
          PluginDiscoveryContentCollectionComponent(
            id: 'fixture-collection',
            layout: PluginDiscoveryContentLayout.list,
            items: <PluginDiscoveryContentItem>[
              PluginDiscoveryContentItem(content: summary, rank: null, metric: null, recommendation: null),
            ],
            continuation: null,
          ),
        ],
      ),
    );
  }

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async {
    searchCalls++;
    return PluginSearchResult(
      pluginId: pluginId,
      sourceName: 'Fixture Source',
      items: <PluginContentSummary>[summary],
      nextCursor: null,
      totalCount: 1,
    );
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by verification engine.');

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async =>
      PluginContentDetail(pluginId: pluginId, sourceName: 'Fixture Source', summary: summary, aliases: const <String>[], catalogUrl: null);

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: 'Fixture Source',
    items: List<PluginChapterSummary>.generate(
      5,
      (index) => PluginChapterSummary(
        id: 'chapter:$index',
        title: 'Chapter $index',
        order: index,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ),
  );

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentChapterIds.add(chapterId);
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: 'Fixture Source',
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: null,
      updatedAt: null,
      text: 'fixture body',
      pages: const <PluginMangaPage>[],
    );
  }
}

final class _DeferredGateway implements SourceContentGateway, SourceChapterGroupGateway {
  final entered = Completer<void>();
  final firstGroup = Completer<PluginChaptersResult>();
  final calls = <String>[];

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: 'Source',
    items: const [],
    groups: [
      PluginMediaGroup(id: 'first', title: 'First', order: 0, episodes: const [], deferred: true),
      PluginMediaGroup(id: 'second', title: 'Second', order: 1, episodes: const [], deferred: true),
    ],
  );

  @override
  Future<PluginChaptersResult> getChapterGroup({required String pluginId, required String id, required String groupId}) {
    calls.add(groupId);
    if (!entered.isCompleted) entered.complete();
    return firstGroup.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected call: ${invocation.memberName}');
}
