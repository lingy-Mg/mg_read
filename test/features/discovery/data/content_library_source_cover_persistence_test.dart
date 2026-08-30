import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    final first = await ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (uri) async {
        expect(uri, url);
        fetchCount += 1;
        return <int>[7, 8, 9];
      },
    ).resolve(BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url));
    expect(first, <int>[7, 8, 9]);
    expect(fetchCount, 1);

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    final second = await ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (_) async {
        fail('A persisted source cover should not be fetched again.');
      },
    ).resolve(BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url));

    expect(second, <int>[7, 8, 9]);
  });

  test('cache misses are direct when cover routing is off and proxied when it is on', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-proxy-');
    final library = await ContentLibrary.open(dataRoot: root);
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originRequests = <Uri>[];
    final proxyRequests = <Uri>[];
    origin.listen((request) async {
      originRequests.add(request.uri);
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    proxy.listen((request) async {
      proxyRequests.add(request.uri);
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
    );

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
}
