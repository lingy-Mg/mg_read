/// Authenticated worker endpoint registrations, typed media, and restart expiry.
/// These are Facade tests; HTTP/player behavior is tested in the SDK/App layers.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test('native resources require active plugin, port and generation', () async {
    final root = await Directory.systemTemp.createTemp('mgread-v2-routing-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const plugin = 'org.mgread.fixture.native';
    var generation = 'a' * 64;
    final resourcePort = server.port + (server.port == 65535 ? -1 : 1);
    String url() =>
        'http://127.0.0.1:$resourcePort/v2/source-resource/native/$plugin/$generation/${'c' * 64}';
    var resourceUrl = url();
    var contentKind = 'audio';
    var registered = true;
    final methods = <String>[];
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer fixture-token');
      final input = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final method = input['method'] as String;
      methods.add(method);
      Object? result = <String, Object?>{};
      if (method == 'source.getContent.v1') {
        result = <String, Object?>{
          'pluginId': plugin,
          'sourceName': 'Fixture',
          'chapterId': 'chapter',
          'contentKind': contentKind,
          'title': null,
          'updatedAt': null,
          'text': null,
          'pages': <Object?>[],
          'media': <String, Object?>{
            'url': resourceUrl,
            'resourceType': contentKind == 'audio' ? 'audio' : 'hls',
            'resourcePolicy': 'sessionOnly',
            'expiresAt': null,
            'mimeType': null,
            'headers': <String, String>{},
          },
        };
      } else if (method == 'runtime.sourceResource.decode.v1') {
        expect((input['params'] as Map)['pluginId'], plugin);
        result = <String, Object?>{
          'pluginId': plugin,
          'request': <String, Object?>{'engine': 'native', 'kind': 'audio'},
        };
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'ok': true,
          'result': result,
          'resourceEndpoints': registered
              ? <Object?>[
                  <String, Object?>{
                    'pluginId': plugin,
                    'generation': generation,
                    'port': resourcePort,
                  },
                ]
              : <Object?>[],
        }),
      );
      await request.response.close();
      if (method == 'runtime.native.shutdown.v1') generation = 'b' * 64;
    });
    final runtime = PluginRuntime.nativeForTesting(
      executablePath: 'unused',
      dataRoot: root.path,
      testControlUri: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      testToken: 'fixture-token',
    );
    addTearDown(() async {
      await runtime.debugDispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    const invocation = SourceContentInvocation(
      pluginId: plugin,
      id: 'content',
      chapterId: 'chapter',
    );
    final invalid = throwsA(
      isA<PluginRuntimeException>().having(
        (e) => e.code,
        'code',
        'invalid_response',
      ),
    );
    registered = false;
    await expectLater(runtime.invoke(invocation), invalid);
    registered = true;
    final content = await runtime.invoke(invocation);
    expect(content.media!.url.toString(), resourceUrl);
    contentKind = 'video';
    expect(
      (await runtime.invoke(invocation)).media!.resourceType,
      PluginMediaResourceType.hls,
    );
    expect(
      (await runtime.invoke(
        SourceResourceDecodeInvocation(url: resourceUrl),
      )).pluginId,
      plugin,
    );
    for (final bad in <String>[
      resourceUrl.replaceFirst(':$resourcePort/', ':123/'),
      resourceUrl.replaceFirst('/$plugin/', '/another.plugin/'),
      resourceUrl.replaceFirst('/$generation/', '/${'d' * 64}/'),
      'http://127.0.0.1:$resourcePort/unrelated',
      'https://upstream.example/video.mp4',
    ]) {
      resourceUrl = bad;
      await expectLater(runtime.invoke(invocation), invalid);
    }
    resourceUrl = url();
    await runtime.configurePluginHttpProxy(
      Uri.parse('socks5://127.0.0.1:1080'),
    );
    expect(runtime.debugDesktopProcessStartCount, 2);
    expect(methods, contains('runtime.native.shutdown.v1'));
    await expectLater(runtime.invoke(invocation), invalid);
    resourceUrl = url();
    expect(
      (await runtime.invoke(invocation)).media!.url.toString(),
      resourceUrl,
    );
  });
}
