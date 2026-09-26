/// Real Node fixture plus a bounded native control endpoint exercise one
/// Facade's engine ownership, source routing, and lifecycle on Windows.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test('one Facade lists and invokes Node and native sources together', () async {
    final repository = nodeRuntimeRepositoryRoot.parent.parent;
    final fixture = Directory.fromUri(
      repository.uri.resolve(
        'integration_test/fixtures/android-runtime-source/',
      ),
    );
    final nodeRoot = await Directory.systemTemp.createTemp(
      'mgread-hybrid-node-',
    );
    final nativeRoot = await Directory.systemTemp.createTemp(
      'mgread-hybrid-native-',
    );
    final versionRoot = Directory(
      '${nodeRoot.path}${Platform.pathSeparator}plugins${Platform.pathSeparator}'
      'org.mgread.android-runtime-fixture${Platform.pathSeparator}versions'
      '${Platform.pathSeparator}1.0.0',
    );
    await Directory(
      '${versionRoot.path}${Platform.pathSeparator}dist',
    ).create(recursive: true);
    await File.fromUri(
      fixture.uri.resolve('package.json'),
    ).copy('${versionRoot.path}${Platform.pathSeparator}package.json');
    await File.fromUri(fixture.uri.resolve('dist/index.mjs')).copy(
      '${versionRoot.path}${Platform.pathSeparator}dist${Platform.pathSeparator}index.mjs',
    );
    await File(
      '${versionRoot.path}${Platform.pathSeparator}package-lock.json',
    ).writeAsString(
      '''{"name":"@mgread-plugin/android-runtime-fixture","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"@mgread-plugin/android-runtime-fixture","version":"1.0.0"}}}''',
    );
    final pluginRoot = versionRoot.parent.parent;
    await File(
      '${pluginRoot.path}${Platform.pathSeparator}pending',
    ).writeAsString('1.0.0\n');
    final artifactRoot = Directory(
      '${nodeRoot.path}${Platform.pathSeparator}plugin-archives'
      '${Platform.pathSeparator}org.mgread.android-runtime-fixture',
    );
    await artifactRoot.create(recursive: true);
    await File(
      '${artifactRoot.path}${Platform.pathSeparator}1.0.0.mgplugin.js',
    ).writeAsString('/* Hybrid test artifact. */\n');

    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final decoded =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final method = decoded['method'] as String? ?? '';
      requests.add(method);
      final result = switch (method) {
        'plugins.list.v1' => <Object?>[
          <String, Object?>{
            'id': 'org.mgread.fixture.native',
            'name': 'Native Fixture',
            'displayName': 'Native Fixture',
            'description': '',
            'iconUrl': null,
            'activeVersion': '1.0.0',
            'pendingVersion': null,
            'enabled': true,
            'status': 'active',
            'contentKinds': <String>['novel'],
            'engine': 'native',
          },
        ],
        'plugins.native.initialize.v1' => {
          'pluginId': 'org.mgread.fixture.native',
          'generation': 'a' * 64,
          'port': server.port,
          'controlToken': 'b' * 64,
        },
        'source.search.v1' => <String, Object?>{
          'pluginId': 'org.mgread.fixture.native',
          'sourceName': 'Native Fixture',
          'items': <Object?>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        'runtime.sourceResource.decode.v1' => <String, Object?>{
          'pluginId': 'org.mgread.fixture.native',
          'request': <String, Object?>{'engine': 'native'},
        },
        'runtime.native.shutdown.v1' => <String, Object?>{},
        _ => <String, Object?>{},
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'result': result,
            'resourceEndpoints': <Object?>[
              <String, Object?>{
                'pluginId': 'org.mgread.fixture.native',
                'generation': 'a' * 64,
                'port': server.port,
              },
            ],
          }),
        );
      await request.response.close();
    });

    final node = PluginRuntime.desktopForTesting(
      runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
      runtimeDataRoot: nodeRoot,
    );
    final native = PluginRuntime.nativeForTesting(
      executablePath: 'unused-in-http-fixture',
      dataRoot: nativeRoot.path,
      testControlUri: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      testToken: 'hybrid-test-token',
    );
    final hybrid = PluginRuntime.hybridForTesting(
      nodeRuntime: node,
      nativeRuntime: native,
    );
    addTearDown(() async {
      await hybrid.debugDispose();
      await server.close(force: true);
      await nodeRoot.delete(recursive: true);
      await nativeRoot.delete(recursive: true);
    });

    final installed = await hybrid.invoke(const InstalledPluginsInvocation());
    expect(
      installed.map((item) => item.id),
      containsAll(<String>[
        'org.mgread.android-runtime-fixture',
        'org.mgread.fixture.native',
      ]),
    );
    expect(
      installed
          .firstWhere((item) => item.id == 'org.mgread.fixture.native')
          .engine,
      PluginEngine.native,
    );

    final nodeSearch = await hybrid.invoke(
      const SourceSearchInvocation(
        pluginId: 'org.mgread.android-runtime-fixture',
        query: 'node',
      ),
    );
    final nativeSearch = await hybrid.invoke(
      const SourceSearchInvocation(
        pluginId: 'org.mgread.fixture.native',
        query: 'native',
      ),
    );
    expect(nodeSearch.items, hasLength(1));
    expect(nativeSearch.items, isEmpty);
    expect(
      requests.where((method) => method == 'source.search.v1'),
      hasLength(1),
    );

    final nodeToken = base64Url
        .encode(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'version': 1,
              'pluginId': 'org.mgread.android-runtime-fixture',
              'request': <String, Object?>{
                'kind': 'image',
                'url': 'https://example.test/image',
              },
            }),
          ),
        )
        .replaceAll('=', '');
    final nodeResource = await hybrid.invoke(
      SourceResourceDecodeInvocation(
        url: 'http://127.0.0.1:12345/v1/source-resource/$nodeToken',
      ),
    );
    expect(nodeResource.pluginId, 'org.mgread.android-runtime-fixture');
    final rebuilt = await hybrid.invoke(
      SourceResourceResolveInvocation(
        url: 'http://127.0.0.1:12345/v1/source-resource/$nodeToken',
      ),
    );
    expect(Uri.parse(rebuilt).port, isNot(12345));
    expect(
      (await hybrid.invoke(
        SourceResourceDecodeInvocation(url: rebuilt),
      )).request,
      nodeResource.request,
    );
    expect(
      requests.where((method) => method == 'runtime.sourceResource.decode.v1'),
      isEmpty,
    );
    String nativeUrlFor(String id) =>
        'http://127.0.0.1:${server.port}/v1/source-resource/${base64Url.encode(utf8.encode(jsonEncode({
          'version': 1,
          'engine': 'native',
          'pluginId': id,
          'request': {'kind': 'image', 'url': 'https://example.test/image'},
        }))).replaceAll('=', '')}';
    final nativeUrl = nativeUrlFor('org.mgread.fixture.native');
    expect(
      (await hybrid.invoke(
        SourceResourceDecodeInvocation(url: nativeUrl),
      )).pluginId,
      'org.mgread.fixture.native',
    );
    await expectLater(
      hybrid.invoke(
        SourceResourceDecodeInvocation(
          url: nativeUrlFor('org.mgread.android-runtime-fixture'),
        ),
      ),
      throwsA(
        isA<PluginRuntimeException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );
    expect(
      requests.where((method) => method == 'runtime.sourceResource.decode.v1'),
      isEmpty,
    );

    const conflictingArtifact = PluginTransferArtifact(
      engine: PluginEngine.native,
      bytes: 1,
      developmentFingerprint: null,
      developmentRevision: null,
      format: PluginArtifactFormat.archive,
      pluginId: 'org.mgread.android-runtime-fixture',
      provenance: PluginArtifactProvenance.installed,
      checksum: 'aaaaaaaa',
      version: '1.0.0',
    );
    final plan = await hybrid.invoke(
      PluginTransferPlanInvocation(
        artifacts: <PluginTransferArtifact>[conflictingArtifact],
      ),
    );
    expect(plan.single.action, PluginTransferPlanAction.unavailable);
    await expectLater(
      hybrid.importPluginArtifacts(
        <({PluginTransferArtifact artifact, Stream<List<int>> bytes})>[
          (
            artifact: conflictingArtifact,
            bytes: const Stream<List<int>>.empty(),
          ),
        ],
      ),
      throwsA(
        isA<PluginRuntimeException>().having(
          (error) => error.code,
          'code',
          'plugin_id_conflict',
        ),
      ),
    );
  });
}
