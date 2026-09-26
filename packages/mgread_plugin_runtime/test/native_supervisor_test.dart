import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  late HttpServer server;
  late Directory dataRoot;
  late List<Map<String, Object?>> requests;
  late Completer<void> slowRequestSeen;
  late Completer<void> exportSeen;
  late Completer<void> releaseExport;
  late Completer<void> uninstallSeen;
  var holdNextPing = false;
  var holdNativeExport = false;

  setUp(() async {
    requests = <Map<String, Object?>>[];
    slowRequestSeen = Completer<void>();
    exportSeen = Completer<void>();
    releaseExport = Completer<void>();
    uninstallSeen = Completer<void>();
    holdNativeExport = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!{
        'Bearer native-test-token',
        'Bearer ${'b' * 64}',
      }.contains(request.headers.value(HttpHeaders.authorizationHeader))) {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, Object?>;
      expect(request.uri.path, isNot('/cancel'));
      expect(decoded.containsKey('id'), isFalse);
      requests.add(decoded);
      if (decoded['method'] == 'plugins.native.export.v1' && holdNativeExport) {
        holdNativeExport = false;
        if (!exportSeen.isCompleted) exportSeen.complete();
        await releaseExport.future;
      }
      if (decoded['method'] == 'plugins.uninstall.v1' &&
          !uninstallSeen.isCompleted) {
        uninstallSeen.complete();
      }
      if (decoded['method'] == 'source.search.v1') {
        if (!slowRequestSeen.isCompleted) slowRequestSeen.complete();
        return;
      }
      if (decoded['method'] == 'runtime.ping' && holdNextPing) {
        holdNextPing = false;
        return;
      }
      if (decoded['method'] == 'plugins.cache.clear.v1') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, Object?>{
              'ok': false,
              'error': <String, Object?>{
                'code': 'io_error',
                'message': 'Cache removal failed after shutdown.',
              },
            }),
          );
        await request.response.close();
        return;
      }
      final result = switch (decoded['method']) {
        'runtime.ping' => <String, Object?>{
          'ok': true,
          'nodeVersion': '',
          'runtimeVersion': 'native-test',
        },
        'runtime.status.v1' => _nativeStatus(),
        'plugins.native.initialize.v1' => {
          'pluginId': 'native-test',
          'generation': 'a' * 64,
          'port': server.port,
          'controlToken': 'b' * 64,
        },
        'plugins.native.export.v1' => <String, Object?>{
          'base64': 'YWJj',
          'checksum': '352441c2',
          'bytes': 3,
          'version': '1.0.0',
        },
        'plugins.transfer.plan.v2' => <Object?>[
          <String, Object?>{
            'action': 'missing',
            'id': 'first-source',
            'receiverVersion': null,
            'version': '1.0.0',
          },
          <String, Object?>{
            'action': 'missing',
            'id': 'second-source',
            'receiverVersion': null,
            'version': '1.0.0',
          },
        ],
        'plugins.native.importBytes.v1' => <String, Object?>{
          'pluginId': 'first-source',
          'version': '1.0.0',
          'restartRequired': true,
        },
        'runtime.native.shutdown.v1' => <String, Object?>{},
        'plugins.uninstall.v1' => <String, Object?>{
          'removed': true,
          'pluginId': 'native-test',
        },
        _ => <String, Object?>{},
      };
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'ok': true, 'result': result}));
      await request.response.close();
    });
    dataRoot = await Directory.systemTemp.createTemp('mgread-native-test-');
  });

  tearDown(() async {
    if (!releaseExport.isCompleted) releaseExport.complete();
    await server.close(force: true);
    if (await dataRoot.exists()) await dataRoot.delete(recursive: true);
  });

  PluginRuntime createRuntime() => PluginRuntime.nativeForTesting(
    executablePath: 'unused-in-http-fixture',
    dataRoot: dataRoot.path,
    testControlUri: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
    testToken: 'native-test-token',
  );

  test(
    'uses authenticated native RPC and preserves the typed ping result',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);

      final ping = await runtime.invoke(const RuntimePingInvocation());

      expect(ping.isHealthy, isTrue);
      expect(ping.nodeVersion, isEmpty);
      expect(ping.runtimeVersion, 'native-test');
      expect(requests, hasLength(1));
      expect(requests.single['method'], 'runtime.ping');
      expect(requests.single['params'], isEmpty);
    },
  );

  test('restarts a stopped worker after cache removal fails', () async {
    final runtime = createRuntime();
    addTearDown(runtime.debugDispose);
    await runtime.invoke(const RuntimePingInvocation());
    await expectLater(
      runtime.invoke(const ClearPluginCacheInvocation(pluginId: 'native-test')),
      throwsA(
        isA<PluginRuntimeException>().having(
          (error) => error.code,
          'error code',
          'io_error',
        ),
      ),
    );
    expect(runtime.debugDesktopProcessStartCount, 2);
    expect(
      (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
      isTrue,
    );
  });

  test(
    'accepts native runtime status through the shared typed decoder',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);

      final status = await runtime.invoke(const RuntimeStatusInvocation());

      expect(status.runtimeKind, 'native-rust');
      expect(status.nodeVersion, isEmpty);
      expect(status.isHealthy, isTrue);
      expect(status.plugins, isEmpty);
    },
  );

  test(
    'materializes only an integrity-checked native package export',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);

      final materialized = await runtime.materializePluginArtifact(
        const PluginTransferOffer(
          developmentFingerprint: null,
          developmentRevision: null,
          format: PluginArtifactFormat.archive,
          pluginId: 'native-test',
          provenance: PluginArtifactProvenance.installed,
          version: '1.0.0',
        ),
      );
      final exported = <int>[];
      await for (final chunk in materialized.bytes) {
        exported.addAll(chunk);
      }

      expect(exported, utf8.encode('abc'));
      expect(materialized.artifact.checksum, '352441c2');
      expect(requests.single['method'], 'plugins.native.export.v1');
      expect(requests.single['params'], <String, Object?>{
        'pluginId': 'native-test',
      });
    },
  );

  test(
    'export holds a lifecycle lease while the host response is pending',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);
      holdNativeExport = true;
      final export = runtime.materializePluginArtifact(
        const PluginTransferOffer(
          developmentFingerprint: null,
          developmentRevision: null,
          format: PluginArtifactFormat.archive,
          pluginId: 'native-test',
          provenance: PluginArtifactProvenance.installed,
          version: '1.0.0',
        ),
      );
      await exportSeen.future.timeout(const Duration(seconds: 2));

      final uninstall = runtime.invoke(
        const UninstallPluginInvocation(pluginId: 'native-test'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(uninstallSeen.isCompleted, isFalse);

      releaseExport.complete();
      await export;
      await uninstall;
      expect(uninstallSeen.isCompleted, isTrue);
      expect(runtime.debugDesktopProcessStartCount, 2);
    },
  );
  test(
    'restarts after a partial transfer import while preserving its failure',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);
      final artifacts =
          <({PluginTransferArtifact artifact, Stream<List<int>> bytes})>[
            (
              artifact: const PluginTransferArtifact(
                bytes: 3,
                developmentFingerprint: null,
                developmentRevision: null,
                format: PluginArtifactFormat.archive,
                pluginId: 'first-source',
                provenance: PluginArtifactProvenance.installed,
                checksum: '352441c2',
                version: '1.0.0',
              ),
              bytes: Stream<List<int>>.value(utf8.encode('abc')),
            ),
            (
              artifact: const PluginTransferArtifact(
                bytes: 3,
                developmentFingerprint: null,
                developmentRevision: null,
                format: PluginArtifactFormat.archive,
                pluginId: 'second-source',
                provenance: PluginArtifactProvenance.installed,
                checksum: '00000000',
                version: '1.0.0',
              ),
              bytes: Stream<List<int>>.value(utf8.encode('xyz')),
            ),
          ];

      await expectLater(
        runtime.importPluginArtifacts(artifacts),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'error code',
            'plugin_transfer_checksum_mismatch',
          ),
        ),
      );

      final imports = requests
          .where(
            (request) => request['method'] == 'plugins.native.importBytes.v1',
          )
          .toList(growable: false);
      expect(imports, hasLength(1));
      expect(imports.single['params'], <String, Object?>{
        'name': 'first-source-1.0.0.mgplugin',
        'expectedPluginId': 'first-source',
        'expectedVersion': '1.0.0',
        'base64': 'YWJj',
      });
      expect(runtime.debugDesktopProcessStartCount, 2);
    },
  );

  test(
    'aborts source HTTP without a cancellation RPC or worker restart',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);
      final cancellation = PluginInvocationCancellation();
      final pending = runtime.invoke(
        const SourceSearchInvocation(pluginId: 'native-test', query: 'book'),
        cancellation: cancellation,
      );
      await slowRequestSeen.future.timeout(const Duration(seconds: 2));

      cancellation.cancel();

      await expectLater(
        pending,
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'error code',
            'cancelled',
          ),
        ),
      );
      expect(
        requests.map((r) => r['method']),
        containsAllInOrder([
          'plugins.native.initialize.v1',
          'source.search.v1',
        ]),
      );
      expect(
        (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
        isTrue,
      );
      expect(runtime.debugDesktopProcessStartCount, 1);
    },
  );

  test(
    'a request timeout drops the worker session before a later restart',
    () async {
      final runtime = createRuntime();
      addTearDown(runtime.debugDispose);
      final proxy = Uri.parse('https://proxy.example:8443');
      await runtime.configurePluginHttpProxy(proxy);
      holdNextPing = true;

      await expectLater(
        runtime.invoke(const RuntimePingInvocation()),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'error code',
            'timeout',
          ),
        ),
      );
      final restartedPing = await runtime.invoke(const RuntimePingInvocation());

      expect(restartedPing.isHealthy, isTrue);
      expect(
        requests.map((request) => request['method']),
        containsAllInOrder(<String>[
          'runtime.native.proxy.v1',
          'runtime.ping',
          'runtime.native.proxy.v1',
          'runtime.ping',
        ]),
      );
      expect(
        requests.where((request) => request['method'] == 'runtime.ping'),
        hasLength(2),
      );
      expect(runtime.debugDesktopProcessStartCount, 2);
    },
  );
}

Map<String, Object?> _nativeStatus() => <String, Object?>{
  'ok': true,
  'nodeVersion': '',
  'runtimeVersion': 'native-test',
  'runtimeKind': 'native-rust',
  'platform': 'windows',
  'arch': 'x86_64',
  'uptimeMs': 12,
  'plugins': <Object?>[],
  'memory': <String, Object?>{
    'arrayBuffers': 0,
    'external': 0,
    'heapTotal': 0,
    'heapUsed': 0,
    'rss': 512,
  },
};
