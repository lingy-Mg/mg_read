import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_tile.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_memory_policy.dart';

const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

ReaderDeviceMemoryInfo _memory(
  int gib, {
  int? available,
  bool lowRam = false,
  bool lowMemory = false,
  int bits = 64,
}) => ReaderDeviceMemoryInfo(
  totalPhysicalBytes: gib * _gib,
  availableBytes: available ?? gib * _gib ~/ 2,
  lowRamDevice: lowRam,
  lowMemory: lowMemory,
  addressBits: bits,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final tier in <int, int?>{
    1: 200,
    2: 200,
    3: 200,
    4: 500,
    6: null,
    8: null,
    12: null,
    16: null,
    32: null,
  }.entries) {
    test(
      '${tier.key} GiB device scales decoded, single-image and byte caches',
      () {
        final policy = ComicImageMemoryPolicy.forDevice(_memory(tier.key));
        if (tier.value == null) {
          expect(policy.decodedBytes, isNull);
          expect(policy.maximumPixels, isNull);
          expect(policy.maximumImagePixels, isNull);
          expect(policy.singleImageDecodedBytes, isNull);
          expect(policy.encodedCacheBytes, 128 * _mib);
        } else {
          expect(policy.decodedBytes, tier.value! * _mib);
          expect(policy.singleImageDecodedBytes, policy.decodedBytes! ~/ 4);
          expect(policy.encodedCacheBytes, policy.decodedBytes! ~/ 4);
          expect(policy.maximumPixels! * 4, policy.decodedBytes);
        }
      },
    );
  }

  test(
    'high-memory devices have no proportional, low-RAM or address-space soft cap outside pressure',
    () {
      expect(
        ComicImageMemoryPolicy.forDevice(
          _memory(16, available: 512 * _mib),
        ).decodedBytes,
        isNull,
      );
      expect(
        ComicImageMemoryPolicy.forDevice(
          _memory(16, lowRam: true),
        ).decodedBytes,
        isNull,
      );
      expect(
        ComicImageMemoryPolicy.forDevice(_memory(16, bits: 32)).decodedBytes,
        isNull,
      );
      expect(
        ComicImageMemoryPolicy.forDevice(_memory(16, lowMemory: true)),
        same(ComicImageMemoryPolicy.pressure),
      );
      expect(
        ComicImageMemoryPolicy.forDevice(_memory(16, available: 0)),
        same(ComicImageMemoryPolicy.pressure),
      );
    },
  );

  test(
    'reserved system RAM still maps a nominal 4 GiB device to the 500 MiB tier',
    () {
      final policy = ComicImageMemoryPolicy.forDevice(
        const ReaderDeviceMemoryInfo(
          totalPhysicalBytes: 3800 * _mib,
          availableBytes: 1500 * _mib,
        ),
      );
      expect(policy.decodedBytes, 500 * _mib);
      final smaller = ComicImageMemoryPolicy.forDevice(_memory(3));
      expect(smaller.decodedBytes, 200 * _mib);
    },
  );

  test('native memory snapshot parsing rejects malformed numbers', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('novel_reader_ui/system');
    final platform = MethodChannelReaderPlatform();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Object? response = <String, Object>{
      'totalPhysicalBytes': 8 * _gib,
      'availableBytes': 4 * _gib,
      'addressBits': 64,
      'lowRamDevice': false,
      'lowMemory': false,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDeviceMemoryInfo');
      return response;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect((await platform.deviceMemoryInfo())?.totalPhysicalBytes, 8 * _gib);
    for (final invalid in <Map<String, Object>>[
      {'totalPhysicalBytes': -1, 'availableBytes': 0, 'addressBits': 64},
      {'totalPhysicalBytes': 1, 'availableBytes': 2, 'addressBits': 64},
      {'totalPhysicalBytes': 1, 'availableBytes': 'unknown', 'addressBits': 64},
      {'totalPhysicalBytes': 1, 'availableBytes': 0, 'addressBits': 0},
    ]) {
      response = invalid;
      expect(await platform.deviceMemoryInfo(), isNull);
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await platform.deviceMemoryInfo(), isNull);
  });

  testWidgets(
    'reader resizes caches, shrinks under pressure and recovers from a fresh snapshot',
    (tester) async {
      final platform = _MemoryPlatform()..memory = _memory(8);
      await _mount(tester, platform);
      await tester.pumpAndSettle();
      expect(_tile(tester).decodeBudget.maximumPixels, isNull);
      expect(_tile(tester).decodeBudget.maximumImagePixels, isNull);
      expect(_tile(tester).cache.maxBytes, 128 * _mib);
      tester.binding.handleMemoryPressure();
      await tester.pump();
      expect(_tile(tester).decodeBudget.maximumPixels! * 4, 32 * _mib);
      expect(_tile(tester).cache.maxBytes, 8 * _mib);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(_tile(tester).decodeBudget.maximumPixels, isNull);
      expect(_tile(tester).decodeBudget.maximumImagePixels, isNull);
      expect(platform.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'old memory probe cannot undo pressure shrink and disposal cancels probe timers',
    (tester) async {
      final pending = Completer<ReaderDeviceMemoryInfo?>();
      final platform = _MemoryPlatform()..pending = pending;
      await _mount(tester, platform);
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_tile(tester).decodeBudget.maximumPixels! * 4, 200 * _mib);
      tester.binding.handleMemoryPressure();
      pending.complete(_memory(16));
      await tester.pump();
      expect(_tile(tester).decodeBudget.maximumPixels! * 4, 32 * _mib);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background stops polling and foreground refreshes current availability',
    (tester) async {
      final platform = _MemoryPlatform()..memory = _memory(16);
      await _mount(tester, platform);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 60));
      expect(platform.calls, 1);
      platform.memory = _memory(16, available: 128 * _mib);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.calls, 2);
      expect(_tile(tester).decodeBudget.maximumPixels! * 4, 32 * _mib);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disposing an unfinished native probe leaves no session timers', (
    tester,
  ) async {
    final pending = Completer<ReaderDeviceMemoryInfo?>();
    final platform = _MemoryPlatform()..pending = pending;
    await _mount(tester, platform);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_memory(16));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

ComicProgressiveImageTile _tile(WidgetTester tester) =>
    tester.widget<ComicProgressiveImageTile>(
      find.byType(ComicProgressiveImageTile).first,
    );

Future<void> _mount(WidgetTester tester, _MemoryPlatform platform) async {
  final previous = ReaderPlatform.instance;
  ReaderPlatform.instance = platform;
  addTearDown(() => ReaderPlatform.instance = previous);
  await tester.pumpWidget(
    MaterialApp(
      home: ComicReaderView(
        bookId: 'book',
        dataSource: _Source(),
        stateStore: _Store(),
        chapterPreloadCount: 0,
      ),
    ),
  );
}

class _MemoryPlatform extends ReaderPlatform {
  ReaderDeviceMemoryInfo? memory;
  Completer<ReaderDeviceMemoryInfo?>? pending;
  int calls = 0;
  @override
  Future<ReaderDeviceMemoryInfo?> deviceMemoryInfo() {
    calls++;
    return pending?.future ?? Future.value(memory);
  }
}

class _Source implements ComicReaderDataSource {
  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async =>
      ComicBookInfo(id: bookId, title: '漫画');
  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: [ComicChapterInfo(id: 'chapter', title: '第一章', index: 0)],
    total: 1,
    hasMore: false,
  );
  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      const ComicChapterInfo(id: 'chapter', title: '第一章', index: 0);
  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: 'chapter',
    title: '第一章',
    images: [ComicImageInfo(id: 'image', index: 0, width: 1, height: 1)],
  );
  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
}

class _Store implements ComicReaderStateStore {
  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => null;
  @override
  Future<ComicReaderPreferences?> loadPreferences() async => null;
  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async => [];
  @override
  Future<void> saveProgress(
    String bookId,
    ComicReaderProgress progress,
  ) async {}
  @override
  Future<void> savePreferences(ComicReaderPreferences preferences) async {}
  @override
  Future<void> addBookmark(ComicReaderBookmark bookmark) async {}
  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}
