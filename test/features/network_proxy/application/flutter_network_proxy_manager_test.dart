import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

void main() {
  test('routes only an enabled Flutter traffic class through the configured proxy', () async {
    final externalProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <Uri>[];
    externalProxy.listen((request) async {
      seen.add(request.uri);
      request.response
        ..statusCode = HttpStatus.ok
        ..write('proxied');
      await request.response.close();
    });
    final manager = FlutterNetworkProxyManager()
      ..update(
        NetworkProxySettings(
          protocol: NetworkProxyProtocol.http,
          host: externalProxy.address.address,
          port: externalProxy.port,
          enabled: <NetworkProxyTraffic, bool>{
            NetworkProxyTraffic.runtime: false,
            NetworkProxyTraffic.manga: true,
            NetworkProxyTraffic.video: false,
            NetworkProxyTraffic.audio: false,
          },
        ),
      );

    final client = await manager.createHttpClient(NetworkProxyTraffic.manga);
    final response = await (await client.getUrl(Uri.parse('http://example.invalid/image'))).close();
    final body = await utf8.decodeStream(response);

    expect(body, 'proxied');
    expect(seen.single.host, 'example.invalid');
    expect(await manager.proxyUriFor(NetworkProxyTraffic.video), isNull);

    final replacementProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    replacementProxy.listen((request) async {
      request.response.write('updated');
      await request.response.close();
    });
    manager.update(
      NetworkProxySettings(
        protocol: NetworkProxyProtocol.http,
        host: replacementProxy.address.address,
        port: replacementProxy.port,
        enabled: <NetworkProxyTraffic, bool>{
          NetworkProxyTraffic.runtime: false,
          NetworkProxyTraffic.manga: true,
          NetworkProxyTraffic.video: false,
          NetworkProxyTraffic.audio: false,
        },
      ),
    );
    final updatedResponse = await (await client.getUrl(Uri.parse('http://example.invalid/next'))).close();

    expect(await utf8.decodeStream(updatedResponse), 'updated');

    client.close(force: true);
    await manager.close();
    await externalProxy.close(force: true);
    await replacementProxy.close(force: true);
  });
}
