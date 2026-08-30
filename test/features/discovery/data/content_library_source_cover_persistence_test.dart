import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/data/content_library_source_cover_persistence.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

void main() {
  test('persists a source cover and reuses it after reopening', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-');
    var library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final url = Uri.parse('https://covers.example/shared.png');
    var fetchCount = 0;
    final firstPersistence = ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (uri) async {
        expect(uri, url);
        fetchCount += 1;
        return <int>[7, 8, 9];
      },
    );
    addTearDown(firstPersistence.dispose);
    final first = await firstPersistence.resolve(
      BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url),
    );
    expect(first, <int>[7, 8, 9]);
    expect(fetchCount, 1);

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    final secondPersistence = ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (_) async {
        fail('A persisted source cover should not be fetched again.');
      },
    );
    addTearDown(secondPersistence.dispose);
    final second = await secondPersistence.resolve(
      BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url),
    );

    expect(second, <int>[7, 8, 9]);
  });

  test('cache misses are direct when cover routing is off and proxied when it is on', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-proxy-');
    final library = await ContentLibrary.open(dataRoot: root);
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originRequests = <Uri>[];
    final originRemotePorts = <int>{};
    final proxyRequests = <Uri>[];
    origin.listen((request) async {
      originRequests.add(request.uri);
      if (request.connectionInfo case final connection?) originRemotePorts.add(connection.remotePort);
      request.response.headers.contentType = request.uri.path == '/not-image' ? ContentType.text : ContentType('image', 'png');
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    proxy.listen((request) async {
      proxyRequests.add(request.uri);
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(<int>[4, 5, 6]);
      await request.response.close();
    });
    final manager = FlutterNetworkProxyManager();
    addTearDown(() async {
      await origin.close(force: true);
      await proxy.close(force: true);
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    NetworkProxySettings settings({required bool cover}) => NetworkProxySettings(
      protocol: NetworkProxyProtocol.http,
      host: proxy.address.address,
      port: proxy.port,
      enabled: <NetworkProxyTraffic, bool>{
        NetworkProxyTraffic.sourceHttp: false,
        NetworkProxyTraffic.cover: cover,
        NetworkProxyTraffic.manga: false,
      },
    );
    var clientCreations = 0;
    final persistence = ContentLibrarySourceCoverPersistence(
      library,
      clientFactory: () {
        clientCreations += 1;
        return manager.createHttpClient(NetworkProxyTraffic.cover);
      },
      clientConfigurationKey: () => manager.proxyUriFor(NetworkProxyTraffic.cover),
    );
    addTearDown(persistence.dispose);

    manager.update(settings(cover: false));
    final direct = await persistence.resolve(
      BookCoverRequest(
        pluginId: 'fixture-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'direct-cover',
        coverUrl: Uri.parse('http://${origin.address.address}:${origin.port}/direct.png'),
      ),
    );

    expect(direct, <int>[1, 2, 3]);
    expect(clientCreations, 1);
    expect(originRequests, hasLength(1));
    expect(proxyRequests, isEmpty);

    final rejectedMime = await persistence.resolve(
      BookCoverRequest(
        pluginId: 'fixture-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'invalid-cover',
        coverUrl: Uri.parse('http://${origin.address.address}:${origin.port}/not-image'),
      ),
    );
    expect(rejectedMime, isNull);
    expect(clientCreations, 1);

    final directAgain = await persistence.resolve(
      BookCoverRequest(
        pluginId: 'fixture-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'direct-cover-2',
        coverUrl: Uri.parse('http://${origin.address.address}:${origin.port}/direct-2.png'),
      ),
    );
    expect(directAgain, <int>[1, 2, 3]);
    expect(clientCreations, 1);
    expect(originRequests, hasLength(3));
    expect(originRemotePorts, hasLength(1));

    manager.update(settings(cover: true));
    final proxied = await persistence.resolve(
      BookCoverRequest(
        pluginId: 'fixture-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'proxied-cover',
        coverUrl: Uri.parse('http://covers.invalid/proxied.png'),
      ),
    );

    expect(proxied, <int>[4, 5, 6]);
    expect(clientCreations, 2);
    expect(proxyRequests.single.host, 'covers.invalid');

    final cached = await persistence.resolve(
      BookCoverRequest(
        pluginId: 'fixture-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'proxied-cover',
        coverUrl: Uri.parse('http://covers.invalid/proxied.png'),
      ),
    );
    expect(cached, <int>[4, 5, 6]);
    expect(clientCreations, 2);
    expect(proxyRequests, hasLength(1));
  });

  test('concurrent identical misses share one remote fetch and persistence result', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-single-flight-');
    final library = await ContentLibrary.open(dataRoot: root);
    final started = Completer<void>();
    final release = Completer<List<int>?>();
    var fetchCount = 0;
    final persistence = ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (_) {
        fetchCount += 1;
        if (!started.isCompleted) started.complete();
        return release.future;
      },
    );
    addTearDown(() async {
      await persistence.dispose();
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final request = BookCoverRequest(
      pluginId: 'fixture-source',
      pluginVersion: '1.0.0',
      remoteContentId: 'single-flight-cover',
      coverUrl: Uri.parse('https://covers.example/single-flight.png'),
    );

    final first = persistence.resolve(request);
    await started.future;
    final second = persistence.resolve(request);
    release.complete(<int>[9, 8, 7]);

    expect(await Future.wait<List<int>?>(<Future<List<int>?>>[first, second]), <List<int>?>[
      <int>[9, 8, 7],
      <int>[9, 8, 7],
    ]);
    expect(fetchCount, 1);
  });

  test('failed covers use a short negative cache and retry after it expires', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-negative-');
    final library = await ContentLibrary.open(dataRoot: root);
    var now = DateTime.utc(2026, 8, 30);
    var fetchCount = 0;
    final persistence = ContentLibrarySourceCoverPersistence(
      library,
      clock: () => now,
      fetcher: (_) async {
        fetchCount += 1;
        return null;
      },
    );
    addTearDown(() async {
      await persistence.dispose();
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final request = BookCoverRequest(
      pluginId: 'fixture-source',
      pluginVersion: '1.0.0',
      remoteContentId: 'missing-cover',
      coverUrl: Uri.parse('https://covers.example/missing.png'),
    );

    expect(await persistence.resolve(request), isNull);
    expect(await persistence.resolve(request), isNull);
    expect(fetchCount, 1);

    now = now.add(const Duration(seconds: 31));
    expect(await persistence.resolve(request), isNull);
    expect(fetchCount, 2);
  });

  test('HTTP owner bounds same-host concurrency and rejects calls after dispose', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstWave = Completer<void>();
    final release = Completer<void>();
    var active = 0;
    var peak = 0;
    server.listen((request) async {
      active += 1;
      peak = peak < active ? active : peak;
      if (active == 4 && !firstWave.isCompleted) firstWave.complete();
      await release.future;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(<int>[1]);
      await request.response.close();
      active -= 1;
    });
    var clientCreations = 0;
    final owner = SourceCoverHttpClientOwner(() async {
      clientCreations += 1;
      return HttpClient()..findProxy = (_) => 'DIRECT';
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await owner.dispose();
      await server.close(force: true);
    });
    final requests = <Future<List<int>?>>[
      for (var index = 0; index < 8; index += 1) owner.fetch(Uri.parse('http://${server.address.address}:${server.port}/cover-$index.png')),
    ];

    await firstWave.future.timeout(const Duration(seconds: 5));
    expect(peak, 4);
    expect(clientCreations, 1);
    release.complete();
    expect(await Future.wait<List<int>?>(requests), everyElement(<int>[1]));

    await owner.dispose();
    await expectLater(owner.fetch(Uri.parse('http://${server.address.address}:${server.port}/after-dispose.png')), throwsStateError);
  });

  test('HTTP owner force-closes and settles an active response on dispose', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    server.listen((request) {
      if (!started.isCompleted) started.complete();
    });
    final owner = SourceCoverHttpClientOwner(() async => HttpClient()..findProxy = (_) => 'DIRECT');
    addTearDown(() async {
      await owner.dispose();
      await server.close(force: true);
    });
    final load = owner.fetch(Uri.parse('http://${server.address.address}:${server.port}/hanging.png'));
    final failure = expectLater(load, throwsA(isA<Object>()));

    await started.future.timeout(const Duration(seconds: 5));
    await owner.dispose().timeout(const Duration(seconds: 5));
    await failure;
  });

  test('deferred app loader keeps one persistence session and rejects after disposal', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-deferred-cover-loader-');
    final library = await ContentLibrary.open(dataRoot: root);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final remotePorts = <int>{};
    server.listen((request) async {
      if (request.connectionInfo case final connection?) remotePorts.add(connection.remotePort);
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(<int>[3, 2, 1]);
      await request.response.close();
    });
    final loader = DeferredBookCoverBytesLoader(() async => library, FlutterNetworkProxyManager());
    addTearDown(() async {
      await loader.dispose();
      await server.close(force: true);
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    for (var index = 0; index < 2; index += 1) {
      expect(
        await loader.resolve(
          BookCoverRequest(
            pluginId: 'fixture-source',
            pluginVersion: '1.0.0',
            remoteContentId: 'deferred-$index',
            coverUrl: Uri.parse('http://${server.address.address}:${server.port}/deferred-$index.png'),
          ),
        ),
        <int>[3, 2, 1],
      );
    }
    expect(remotePorts, hasLength(1));

    await loader.dispose();
    await expectLater(
      loader.resolve(
        BookCoverRequest(
          pluginId: 'fixture-source',
          pluginVersion: '1.0.0',
          remoteContentId: 'disposed',
          coverUrl: Uri.parse('http://${server.address.address}:${server.port}/disposed.png'),
        ),
      ),
      throwsStateError,
    );
  });
}
