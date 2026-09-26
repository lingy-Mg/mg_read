/// Facade ownership and delayed-load restart recovery; not player acceptance.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test(
    'resolves saved descriptors after restart without another content call',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-http-routing-',
      );
      final manager = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var pluginServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const plugin = 'org.mgread.fixture.native';
      var generation = 'a' * 64;
      var contentCalls = 0;
      String url(int port, {String owner = plugin, String engine = 'native'}) =>
          'http://127.0.0.1:$port/v1/source-resource/${base64Url.encode(utf8.encode(jsonEncode({
            'version': 1,
            'engine': engine,
            'pluginId': owner,
            'request': {'kind': 'image', 'url': 'https://upstream.example/image'},
          }))).replaceAll('=', '')}';
      var resultUrl = url(pluginServer.port);
      void listenPlugin(HttpServer server) {
        server.listen((request) async {
          if (request.method == 'GET') {
            request.response.write('image-after-restart');
            await request.response.close();
            return;
          }
          expect(request.uri.path, '/invoke');
          expect(request.headers.value('authorization'), 'Bearer ${'b' * 64}');
          final input =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(input.containsKey('id'), isFalse);
          contentCalls++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'ok': true,
              'result': {
                'pluginId': plugin,
                'sourceName': 'Fixture',
                'chapterId': 'chapter',
                'contentKind': 'audio',
                'title': null,
                'updatedAt': null,
                'text': null,
                'pages': [],
                'media': {
                  'url': resultUrl,
                  'resourceType': 'audio',
                  'resourcePolicy': 'sessionOnly',
                  'expiresAt': null,
                  'mimeType': null,
                  'headers': {},
                },
              },
            }),
          );
          await request.response.close();
        });
      }

      listenPlugin(pluginServer);
      manager.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture-token');
        final input =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (input['method'] == 'runtime.native.shutdown.v1') {
          await pluginServer.close(force: true);
          pluginServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          listenPlugin(pluginServer);
          generation = 'd' * 64;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': true,
            'result': input['method'] == 'plugins.native.initialize.v1'
                ? {
                    'pluginId': plugin,
                    'generation': generation,
                    'port': pluginServer.port,
                    'controlToken': 'b' * 64,
                  }
                : {},
          }),
        );
        await request.response.close();
      });
      final runtime = PluginRuntime.nativeForTesting(
        executablePath: 'unused',
        dataRoot: root.path,
        testControlUri: Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: manager.port,
        ),
        testToken: 'fixture-token',
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await manager.close(force: true);
        await pluginServer.close(force: true);
        await root.delete(recursive: true);
      });
      const invocation = SourceContentInvocation(
        pluginId: plugin,
        id: 'content',
        chapterId: 'chapter',
      );
      final content = await runtime.invoke(invocation);
      final saved = content.media!.url.toString();
      expect(
        (await runtime.invoke(
          SourceResourceDecodeInvocation(url: saved),
        )).pluginId,
        plugin,
      );
      for (final bad in [
        url(123),
        url(pluginServer.port, owner: 'another.plugin'),
        url(pluginServer.port, engine: 'node'),
        'https://upstream.example/video.mp4',
      ]) {
        resultUrl = bad;
        await expectLater(
          runtime.invoke(invocation),
          throwsA(
            isA<PluginRuntimeException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
      final callsBeforeRestart = contentCalls;
      await runtime.configurePluginHttpProxy(
        Uri.parse('socks5://127.0.0.1:1080'),
      );
      final resolved = await runtime.invoke(
        SourceResourceResolveInvocation(url: saved),
      );
      expect(Uri.parse(resolved).port, pluginServer.port);
      expect(Uri.parse(resolved).path, Uri.parse(saved).path);
      expect(contentCalls, callsBeforeRestart);
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      final response = await (await client.getUrl(Uri.parse(resolved))).close();
      expect(await utf8.decoder.bind(response).join(), 'image-after-restart');
      client.close(force: true);
      expect(runtime.debugDesktopProcessStartCount, 2);
      expect(
        await runtime.invoke(
          const SourceResourceResolveInvocation(
            url: 'https://example.org/direct.png',
          ),
        ),
        'https://example.org/direct.png',
      );
    },
  );
}
