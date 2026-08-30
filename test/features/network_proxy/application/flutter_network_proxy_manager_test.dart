import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

void main() {
  test('returns and uses the configured upstream directly without a loopback adapter', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <Uri>[];
    proxy.listen((request) async {
      seen.add(request.uri);
      request.response.write('proxied');
      await request.response.close();
    });
    addTearDown(() => proxy.close(force: true));
    final manager = FlutterNetworkProxyManager()..update(_settings(proxy, manga: true));

    final endpoint = manager.proxyUriFor(NetworkProxyTraffic.manga);
    expect(endpoint, Uri(scheme: 'http', host: proxy.address.address, port: proxy.port));

    final client = await manager.createHttpClient(NetworkProxyTraffic.manga);
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(Uri.parse('http://example.invalid/image'))).close();

    expect(await utf8.decodeStream(response), 'proxied');
    expect(seen.single.host, 'example.invalid');
    expect(manager.proxyUriFor(NetworkProxyTraffic.sourceHttp), isNull);
  });

  test('keeps loopback resources direct when a Flutter route is enabled', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var proxyRequests = 0;
    origin.listen((request) async {
      request.response.write('local');
      await request.response.close();
    });
    proxy.listen((request) async {
      proxyRequests += 1;
      request.response.write('wrong');
      await request.response.close();
    });
    addTearDown(() async {
      await origin.close(force: true);
      await proxy.close(force: true);
    });
    final manager = FlutterNetworkProxyManager()..update(_settings(proxy, cover: true));
    final client = await manager.createHttpClient(NetworkProxyTraffic.cover);
    addTearDown(() => client.close(force: true));

    final response = await (await client.getUrl(Uri.parse('http://${origin.address.address}:${origin.port}/resource'))).close();

    expect(await utf8.decodeStream(response), 'local');
    expect(proxyRequests, 0);
  });

  test('sends an HTTPS target directly to the configured HTTP proxy', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connectHost = Completer<String?>();
    proxy.listen((request) async {
      if (!connectHost.isCompleted) connectHost.complete(request.headers.value(HttpHeaders.hostHeader));
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });
    addTearDown(() => proxy.close(force: true));
    final manager = FlutterNetworkProxyManager()..update(_settings(proxy, manga: true));
    final client = await manager.createHttpClient(NetworkProxyTraffic.manga);
    addTearDown(() => client.close(force: true));

    await expectLater(() async => (await client.getUrl(Uri.parse('https://example.invalid/image'))).close(), throwsA(anything));
    expect(await connectHost.future.timeout(const Duration(seconds: 5)), 'example.invalid:443');
  });

  test('connects a Flutter HTTP client directly through SOCKS5', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final targetHost = Completer<String>();
    proxy.listen((socket) async {
      final messages = StreamIterator<List<int>>(socket);
      await messages.moveNext();
      socket.add(<int>[5, 0]);
      await socket.flush();
      await messages.moveNext();
      final request = messages.current;
      final hostLength = request[4];
      targetHost.complete(utf8.decode(request.sublist(5, 5 + hostLength)));
      socket.add(<int>[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
      await socket.flush();
      await messages.moveNext();
      socket.write('HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nsocks');
      await socket.flush();
      await socket.close();
    });
    addTearDown(proxy.close);
    final manager = FlutterNetworkProxyManager()
      ..update(
        NetworkProxySettings(
          protocol: NetworkProxyProtocol.socks5,
          host: proxy.address.address,
          port: proxy.port,
          enabled: const <NetworkProxyTraffic, bool>{
            NetworkProxyTraffic.sourceHttp: false,
            NetworkProxyTraffic.cover: false,
            NetworkProxyTraffic.manga: true,
          },
        ),
      );
    final client = await manager.createHttpClient(NetworkProxyTraffic.manga);
    addTearDown(() => client.close(force: true));

    final response = await (await client.getUrl(Uri.parse('http://example.invalid/resource'))).close();

    expect(await utf8.decodeStream(response), 'socks');
    expect(await targetHost.future.timeout(const Duration(seconds: 5)), 'example.invalid');
  });

  test('exposes only an enabled HTTP endpoint to MediaKit player routes', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final manager = FlutterNetworkProxyManager()..update(_settings(proxy, video: true));

    expect(manager.playerProxyUriFor(NetworkProxyTraffic.video), Uri(scheme: 'http', host: proxy.address.address, port: proxy.port));
    expect(manager.playerProxyUriFor(NetworkProxyTraffic.audio), isNull);
    expect(() => manager.playerProxyUriFor(NetworkProxyTraffic.cover), throwsArgumentError);

    manager.update(
      NetworkProxySettings(
        protocol: NetworkProxyProtocol.socks5,
        host: proxy.address.address,
        port: proxy.port,
        enabled: const <NetworkProxyTraffic, bool>{NetworkProxyTraffic.video: true},
      ),
    );
    expect(manager.playerProxyUriFor(NetworkProxyTraffic.video), isNull);
  });
}

NetworkProxySettings _settings(HttpServer proxy, {bool cover = false, bool manga = false, bool video = false}) => NetworkProxySettings(
  protocol: NetworkProxyProtocol.http,
  host: proxy.address.address,
  port: proxy.port,
  enabled: <NetworkProxyTraffic, bool>{
    NetworkProxyTraffic.sourceHttp: false,
    NetworkProxyTraffic.cover: cover,
    NetworkProxyTraffic.manga: manga,
    NetworkProxyTraffic.video: video,
  },
);
