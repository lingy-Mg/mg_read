import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_comic_reader.dart';

void main() {
  test('a truncated image response retries without retaining its connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var calls = 0;
    final sockets = <Socket>[];
    addTearDown(() {
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    server.listen((socket) {
      sockets.add(socket);
      var handled = false;
      socket.listen((_) async {
        if (handled) return;
        handled = true;
        calls++;
        socket.write('HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\nConnection: close\r\n\r\n');
        socket.add(calls == 1 ? [1] : [1, 2, 3]);
        await socket.flush();
        socket.destroy();
      });
    });
    final client = HttpClient()
      ..maxConnectionsPerHost = 1
      ..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('http://127.0.0.1:${server.port}/image');
    expect(await fetchComicImage(uri, client: client).timeout(const Duration(seconds: 4)), [1, 2, 3]);
    expect(calls, 2);
  });

  test('transient image failures retry and unread responses release pooled connections', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient()
      ..maxConnectionsPerHost = 1
      ..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    var calls = 0;
    server.listen((request) async {
      calls++;
      if (calls <= 2) {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.contentLength = 100;
        request.response.write('x');
        await request.response.flush();
        // Deliberately leave the error body incomplete. The client must abort
        // this response before retry can acquire the single pooled connection.
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add([1, 2, 3]);
        await request.response.close();
      }
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/image');
    expect(await fetchComicImage(uri, client: client).timeout(const Duration(seconds: 4)), [1, 2, 3]);
    expect(calls, 3);
  });

  test('permanent image status fails once and transient retries are bounded', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    var status = HttpStatus.notFound;
    server.listen((request) async {
      calls++;
      request.response.statusCode = status;
      await request.response.close();
    });
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('http://127.0.0.1:${server.port}/image');
    await expectLater(fetchComicImage(uri, client: client), throwsA(isA<ComicImageHttpStatusException>()));
    expect(calls, 1);
    calls = 0;
    status = HttpStatus.serviceUnavailable;
    await expectLater(fetchComicImage(uri, client: client), throwsA(isA<ComicImageHttpStatusException>()));
    expect(calls, 3);
  });

  test('syncs the full catalog and round-trips a session manifest', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(
      chapters: const <_ChapterFixture>[_ChapterFixture('chapter-1', '第一章', 0), _ChapterFixture('chapter-2', '第二章', 1)],
      pages: <PluginMangaPage>[_page(policy: PluginMangaPageResourcePolicy.sessionOnly)],
    );
    final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);
    final book = await adapter.loadBookInfo(fixture.manga.id.value);
    expect(book.sourceName, 'fixture');
    expect(book.sourceUrl, Uri.parse('https://fixture.example/comic'));

    final firstPage = await adapter.loadChapterCatalog(fixture.manga.id.value, pageSize: 1);
    final secondPage = await adapter.loadChapterCatalog(fixture.manga.id.value, cursor: firstPage.nextCursor, pageSize: 1);
    expect(firstPage.items.single.id, 'chapter-1');
    expect(secondPage.items.single.id, 'chapter-2');
    expect(firstPage.total, 2);
    expect(gateway.chapterCalls, 1);

    final session = await fixture.library.openMangaReaderSession(fixture.manga.id);
    expect((await session!.itemByRemoteIdentity('chapter-2'))!.index, 1);
    final content = await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    expect(
      content.images.single,
      const ComicImageInfo(id: 'image-1', index: 0, width: 100, height: 200, contentType: 'image/png', contentVersion: '1700000000000'),
    );
    expect((await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1')).images, content.images);
    expect(gateway.contentCalls, 1);

    final entry = await session.itemByRemoteIdentity('chapter-1');
    final persisted = await session.readContent(entry!);
    expect(persisted, isA<MangaChapterContent>());
    final persistedPage = (persisted! as MangaChapterContent).pages.single;
    expect(persistedPage.resource.persistencePolicy, PersistencePolicy.sessionOnly);
    expect(persistedPage.resource.url, isNull);
    expect(persistedPage.mimeType, 'image/png');
    expect(persistedPage.width, 100);
    expect(persistedPage.height, 200);
    expect(persistedPage.contentVersion, 1700000000000);
  });

  test('keeps image bytes memory-only and refreshes session-only URLs in a new adapter', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(
      pages: <PluginMangaPage>[
        _page(policy: PluginMangaPageResourcePolicy.sessionOnly),
        _page(id: 'image-2', index: 1, policy: PluginMangaPageResourcePolicy.sessionOnly),
      ],
      varyUrlByCall: true,
    );
    final fetched = <Uri>[];
    Future<Uint8List> fetch(Uri uri) async {
      fetched.add(uri);
      return Uint8List.fromList(<int>[1, 2, 3]);
    }

    final first = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga, fetcher: fetch);
    await first.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    await first.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');
    expect(gateway.contentCalls, 1);

    final rebuilt = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga, fetcher: fetch);
    expect(await rebuilt.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'), <int>[1, 2, 3]);
    expect(gateway.contentCalls, 2, reason: 'a new adapter must refresh the session-only URL');
    await rebuilt.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-2');
    expect(gateway.contentCalls, 2);
    expect(fetched.map((uri) => uri.queryParameters['generation']), <String?>['1', '2', '2']);
  });

  test('opens persisted catalog and manifest offline but does not persist image bytes', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final online = _Gateway(pages: <PluginMangaPage>[_page()]);
    final first = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: online,
      item: fixture.manga,
      fetcher: (_) async => Uint8List.fromList(<int>[7, 8, 9]),
    );
    await first.loadChapterCatalog(fixture.manga.id.value);
    await first.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    await first.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');

    final offline = _Gateway(failChapters: true, failContent: true);
    final rebuilt = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: offline,
      item: fixture.manga,
      fetcher: (_) async => throw StateError('network offline'),
    );
    expect((await rebuilt.loadChapterCatalog(fixture.manga.id.value)).items.single.id, 'chapter-1');
    expect((await rebuilt.loadChapterContent(fixture.manga.id.value, 'chapter-1')).images.single.id, 'image-1');
    await expectLater(rebuilt.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'), throwsA(isA<ReaderFailure>()));
    expect(offline.chapterCalls, 0);
    expect(offline.contentCalls, 0, reason: 'a valid durable manifest should open without probing the offline source');
  });

  test('keeps only three recently used runtime manifests', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(
      chapters: const <_ChapterFixture>[
        _ChapterFixture('chapter-1', '第一章', 0),
        _ChapterFixture('chapter-2', '第二章', 1),
        _ChapterFixture('chapter-3', '第三章', 2),
        _ChapterFixture('chapter-4', '第四章', 3),
      ],
      pages: <PluginMangaPage>[_page(policy: PluginMangaPageResourcePolicy.sessionOnly)],
    );
    final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);

    for (final chapterId in <String>['chapter-1', 'chapter-2', 'chapter-3']) {
      await adapter.loadChapterContent(fixture.manga.id.value, chapterId);
    }
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-4');
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-2');

    expect(gateway.contentCalls, 5, reason: 'touching chapter-1 makes chapter-2 the least recently used manifest');
  });

  test('keeps a validated runtime manifest readable when its cache write fails', () async {
    final fixture = await _LibraryFixture.open(withSettings: true);
    addTearDown(fixture.close);
    final gateway = _Gateway(pages: <PluginMangaPage>[_page(policy: PluginMangaPageResourcePolicy.durable)]);
    final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);

    await adapter.loadChapterCatalog(fixture.manga.id.value);
    await fixture.persistence!.contentObjects.close();

    final content = await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');

    expect(content.images.single.id, 'image-1');
    expect(gateway.contentCalls, 1);
  });

  test('refreshes an expired refreshable URL before downloading', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(
      pages: <PluginMangaPage>[_page(policy: PluginMangaPageResourcePolicy.refreshable, expiresAt: DateTime.utc(2020))],
      varyUrlByCall: true,
    );
    final fetched = <Uri>[];
    final adapter = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: gateway,
      item: fixture.manga,
      fetcher: (uri) async {
        fetched.add(uri);
        return Uint8List.fromList(<int>[5]);
      },
    );
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    await adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');
    expect(gateway.contentCalls, 2);
    expect(fetched.single.queryParameters['generation'], '2');
  });

  test('refreshes and retries only once after an explicit authorization failure', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(pages: <PluginMangaPage>[_page()], varyUrlByCall: true);
    final fetched = <Uri>[];
    final adapter = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: gateway,
      item: fixture.manga,
      fetcher: (uri) async {
        fetched.add(uri);
        throw ComicImageHttpStatusException(HttpStatus.unauthorized, uri);
      },
    );
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');

    await expectLater(
      adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'),
      throwsA(isA<ReaderFailure>().having((failure) => failure.code, 'code', 'library_comic_image_download_failed')),
    );

    expect(gateway.contentCalls, 2);
    expect(fetched.map((uri) => uri.queryParameters['generation']), <String?>['1', '2']);
  });

  test('persists durable and refreshable resource metadata', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final expiresAt = DateTime.utc(2030, 1, 2);
    final gateway = _Gateway(
      pages: <PluginMangaPage>[
        _page(),
        _page(id: 'image-2', index: 1, policy: PluginMangaPageResourcePolicy.refreshable, expiresAt: expiresAt),
      ],
    );
    final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);
    await adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1');

    final session = await fixture.library.openMangaReaderSession(fixture.manga.id);
    final entry = await session!.itemByRemoteIdentity('chapter-1');
    final persisted = await session.readContent(entry!);
    final pages = (persisted! as MangaChapterContent).pages;
    expect(pages.first.resource.persistencePolicy, PersistencePolicy.durable);
    expect(pages.first.resource.url, Uri.parse('https://fixture/image.png'));
    expect(pages.last.resource.persistencePolicy, PersistencePolicy.refreshable);
    expect(pages.last.resource.url, Uri.parse('https://fixture/image.png'));
    expect(pages.last.resource.expiresAtUtc, expiresAt);
    expect(pages.map((page) => page.contentVersion), everyElement(1700000000000));

    final reopened = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);
    addTearDown(reopened.dispose);
    final cached = await reopened.loadChapterContent(fixture.manga.id.value, 'chapter-1');
    expect(cached.images, hasLength(2));
    expect(gateway.contentCalls, 1, reason: 'valid durable and refreshable URLs should not require a Runtime manifest refresh');
  });

  test('single-flights concurrent requests for the same image', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final gateway = _Gateway(pages: <PluginMangaPage>[_page()]);
    final release = Completer<void>();
    final started = Completer<void>();
    var fetchCalls = 0;
    Future<Uint8List> fetch(Uri _) async {
      fetchCalls++;
      if (!started.isCompleted) started.complete();
      await release.future;
      return Uint8List.fromList(<int>[9]);
    }

    final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga, fetcher: fetch);
    final first = adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');
    final second = adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');
    await started.future.timeout(const Duration(seconds: 5));
    expect(fetchCalls, 1);
    release.complete();
    expect(await Future.wait(<Future<Uint8List>>[first, second]), everyElement(<int>[9]));
    expect(gateway.contentCalls, 1);
  });

  test('reuses one owned HTTP client for multiple images and closes it on dispose', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final baseUri = Uri.parse('http://${server.address.address}:${server.port}');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    var clientFactoryCalls = 0;
    final adapter = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: _Gateway(
        pages: <PluginMangaPage>[
          _page(url: baseUri.resolve('/image-1')),
          _page(id: 'image-2', index: 1, url: baseUri.resolve('/image-2')),
        ],
      ),
      item: fixture.manga,
      httpClientFactory: () async {
        clientFactoryCalls++;
        return client;
      },
    );

    await Future.wait<Uint8List>(<Future<Uint8List>>[
      adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'),
      adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-2'),
    ]);
    expect(clientFactoryCalls, 1);

    await adapter.dispose().timeout(const Duration(seconds: 5));
    expect(() => client.getUrl(baseUri.resolve('/after-dispose')), throwsStateError);
    expect(() => adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'), throwsStateError);
  });

  test('does not close a caller-owned HTTP client', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(<int>[4]);
      await request.response.close();
    });
    final uri = Uri.parse('http://${server.address.address}:${server.port}/image');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));

    expect(await fetchComicImage(uri, client: client), <int>[4]);
    expect(await fetchComicImage(uri, client: client), <int>[4]);
  });

  test('dispose completes an active owned request without an unhandled error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestStarted = Completer<void>();
    server.listen((request) {
      if (!requestStarted.isCompleted) requestStarted.complete();
    });
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    final uri = Uri.parse('http://${server.address.address}:${server.port}/pending');
    final adapter = ContentLibraryComicReaderDataSource(
      library: fixture.library,
      gateway: _Gateway(pages: <PluginMangaPage>[_page(url: uri)]),
      item: fixture.manga,
      httpClientFactory: () async => HttpClient()..findProxy = (_) => 'DIRECT',
    );

    final pending = adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1');
    await requestStarted.future.timeout(const Duration(seconds: 5));
    await adapter.dispose().timeout(const Duration(seconds: 5));
    await expectLater(pending.timeout(const Duration(seconds: 5)), throwsA(isA<ReaderFailure>()));
  });

  test('rejects non-manga, empty, duplicate and incomplete refreshable manifests', () async {
    final fixture = await _LibraryFixture.open();
    addTearDown(fixture.close);
    Future<void> expectRejected(_Gateway gateway) async {
      final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);
      await expectLater(adapter.loadChapterContent(fixture.manga.id.value, 'chapter-1'), throwsStateError);
    }

    await expectRejected(_Gateway(contentKind: PluginContentKind.novel, pages: const <PluginMangaPage>[]));
    await expectRejected(_Gateway(pages: const <PluginMangaPage>[]));
    await expectRejected(_Gateway(pages: <PluginMangaPage>[_page(), _page(index: 1)]));
    await expectRejected(_Gateway(pages: <PluginMangaPage>[_page(policy: PluginMangaPageResourcePolicy.refreshable)]));
  });

  test('round-trips unified comic progress, preferences and bookmarks', () async {
    final fixture = await _LibraryFixture.open(withSettings: true);
    addTearDown(fixture.close);
    final store = ContentLibraryComicReaderStateStore(fixture.library, itemId: fixture.manga.id, settings: fixture.settings);
    const progress = ComicReaderProgress(chapterId: 'chapter-1', imageId: 'image-1', imageFraction: .4, chapterIndex: 0, bookFraction: .4);
    const preferences = ComicReaderPreferences(brightness: .6, keepScreenOn: false, immersiveMode: true, imageSpacing: 12);
    final bookmark = ComicReaderBookmark(
      id: 'bookmark-1',
      bookId: fixture.manga.id.value,
      chapterId: 'chapter-1',
      imageId: 'image-1',
      imageFraction: .5,
      chapterTitle: '第一章',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    await store.saveProgress(fixture.manga.id.value, progress);
    await store.savePreferences(preferences);
    await store.addBookmark(bookmark);
    expect(await store.loadProgress(fixture.manga.id.value), progress);
    expect(await store.loadPreferences(), preferences.normalized());
    expect((await store.loadBookmarks(fixture.manga.id.value)).single.id, bookmark.id);
    expect(await fixture.library.loadProgress(fixture.manga.id), isA<LibraryMangaReadingProgress>());
    expect(await fixture.library.loadBookmarks(fixture.manga.id, ContentKind.manga), hasLength(1));
    expect(fixture.settings!.get(AppSettingKeys.readerPreferences), isEmpty);

    await store.removeBookmark(fixture.manga.id.value, bookmark.id);
    expect(await store.loadBookmarks(fixture.manga.id.value), isEmpty);
    await expectLater(store.loadProgress('other-book'), throwsArgumentError);
    expect(() => store.saveProgress('other-book', progress), throwsArgumentError);
    await expectLater(store.loadBookmarks('other-book'), throwsArgumentError);
    expect(() => store.removeBookmark('other-book', bookmark.id), throwsArgumentError);
    expect(() => store.addBookmark(_bookmarkFor('other-book')), throwsArgumentError);
  });

  for (final failure in <String, Future<void> Function(HttpResponse)>{
    'non-2xx': (response) async {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType('image', 'png');
      response.add(<int>[1]);
    },
    'non-image': (response) async {
      response.headers.contentType = ContentType.text;
      response.write('not an image');
    },
    'empty': (response) async {
      response.headers.contentType = ContentType('image', 'png');
    },
    'larger than 8 MiB': (response) async {
      response.headers.contentType = ContentType('image', 'png');
      final chunk = Uint8List(1024 * 1024);
      for (var index = 0; index < 9; index++) {
        response.add(chunk);
      }
    },
  }.entries) {
    test('default HTTP image fetch rejects ${failure.key}', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await failure.value(request.response);
        await request.response.close();
      });
      final fixture = await _LibraryFixture.open();
      addTearDown(fixture.close);
      final gateway = _Gateway(pages: <PluginMangaPage>[_page(url: Uri.parse('http://${server.address.address}:${server.port}/image'))]);
      final adapter = ContentLibraryComicReaderDataSource(library: fixture.library, gateway: gateway, item: fixture.manga);
      await expectLater(adapter.loadImageBytes(fixture.manga.id.value, 'chapter-1', 'image-1'), throwsA(anything));
    });
  }
}

ComicReaderBookmark _bookmarkFor(String bookId) => ComicReaderBookmark(
  id: 'wrong-bookmark',
  bookId: bookId,
  chapterId: 'chapter-1',
  imageId: 'image-1',
  imageFraction: 0,
  chapterTitle: '第一章',
  createdAt: DateTime.utc(2026),
);

PluginMangaPage _page({
  String id = 'image-1',
  int index = 0,
  Uri? url,
  PluginMangaPageResourcePolicy policy = PluginMangaPageResourcePolicy.durable,
  DateTime? expiresAt,
}) => PluginMangaPage(
  id: id,
  index: index,
  url: url ?? Uri.parse('https://fixture/image.png'),
  mimeType: 'image/png',
  width: 100,
  height: 200,
  resourcePolicy: policy,
  expiresAt: expiresAt,
);

final class _LibraryFixture {
  _LibraryFixture._({required this.root, required this.library, required this.manga, this.persistence, this.settings});

  final Directory root;
  final ContentLibrary library;
  final LibraryItem manga;
  final AppPersistence? persistence;
  final AppSettingsManager? settings;

  static Future<_LibraryFixture> open({bool withSettings = false}) async {
    final root = await Directory.systemTemp.createTemp('comic-reader-test-');
    if (!withSettings) {
      final library = await ContentLibrary.open(dataRoot: root);
      final manga = await library.addLibraryItem(_mangaRequest);
      return _LibraryFixture._(root: root, library: library, manga: manga);
    }
    final registry = RecordDocumentRegistry(<RecordDocumentCodec>[
      ...contentLibraryRecordDocumentCodecs,
      ...settingsRecordDocumentCodecs(AppSettingKeys.registry, scopeKind: 'app'),
    ]);
    final persistence = await AppPersistence.open(dataRoot: root, registry: registry);
    final library = ContentLibrary.fromPersistence(persistence);
    final settings = AppSettingsManager(
      store: PersistentSettingsStore(
        records: persistence.metadataRecords,
        scope: const ScopeKey(kind: 'app', id: 'primary'),
        registry: AppSettingKeys.registry,
      ),
      registry: AppSettingKeys.registry,
    );
    await settings.initialize();
    final manga = await library.addLibraryItem(_mangaRequest);
    return _LibraryFixture._(root: root, library: library, manga: manga, persistence: persistence, settings: settings);
  }

  Future<void> close() async {
    await settings?.close();
    await library.close();
    await persistence?.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final _mangaRequest = BookshelfAddRequest(
  pluginId: 'fixture',
  pluginVersion: '1',
  remoteContentId: 'comic',
  title: '漫画',
  author: null,
  kind: ContentKind.manga,
  sourceName: 'fixture',
  sourceUrl: Uri.parse('https://fixture.example/comic'),
);

final class _ChapterFixture {
  const _ChapterFixture(this.id, this.title, this.order);
  final String id;
  final String title;
  final int order;
}

final class _Gateway implements SourceContentGateway {
  _Gateway({
    this.chapters = const <_ChapterFixture>[_ChapterFixture('chapter-1', '第一章', 0)],
    this.pages = const <PluginMangaPage>[],
    this.contentKind = PluginContentKind.manga,
    this.varyUrlByCall = false,
    this.failChapters = false,
    this.failContent = false,
  });

  final List<_ChapterFixture> chapters;
  final List<PluginMangaPage> pages;
  final PluginContentKind contentKind;
  final bool varyUrlByCall;
  final bool failChapters;
  final bool failContent;
  var chapterCalls = 0;
  var contentCalls = 0;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => const <PluginSourceDescriptor>[];

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
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
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    chapterCalls++;
    if (failChapters) throw StateError('source offline');
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: 'fixture',
      items: [
        for (final chapter in chapters)
          PluginChapterSummary(
            id: chapter.id,
            title: chapter.title,
            order: chapter.order,
            url: null,
            volumeTitle: null,
            wordCount: null,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
            isLocked: false,
            attributes: const <PluginContentAttribute>[],
          ),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls++;
    if (failContent) throw StateError('source offline');
    final generation = '$contentCalls';
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: 'fixture',
      contentKind: contentKind,
      chapterId: chapterId,
      title: '第一章',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      text: contentKind == PluginContentKind.novel ? 'text' : null,
      pages: [
        for (final page in pages)
          PluginMangaPage(
            id: page.id,
            index: page.index,
            url: varyUrlByCall ? page.url.replace(queryParameters: <String, String>{'generation': generation}) : page.url,
            mimeType: page.mimeType,
            width: page.width,
            height: page.height,
            resourcePolicy: page.resourcePolicy,
            expiresAt: page.expiresAt,
          ),
      ],
    );
  }
}
