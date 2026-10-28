/// Release-only device benchmark entrypoint. The host runner owns process cold
/// starts, alternating backend order, memory sampling and the control endpoint.
/// This isolated app uses the production Node Facade without the common Rust
/// backend. No application database, production sources or VPN settings change.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

const _plugin = 'org.mgread.android-runtime-benchmark';
final _client = HttpClient()..findProxy = (_) => 'DIRECT';
final _root = Uri.parse('http://127.0.0.1:${const int.fromEnvironment('MGREAD_BENCH_CONTROL_PORT', defaultValue: 18764)}');

Future<dynamic> _control(String path, [Map<String, Object?>? body]) async {
  final request = await _client.openUrl(body == null ? 'GET' : 'POST', _root.resolve(path));
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  if (response.statusCode != 200) throw StateError('Benchmark controller: ${response.statusCode}');
  return jsonDecode(text);
}

Future<void> _event(String phase, [Map<String, Object?> data = const {}]) async => _control('/event', {'phase': phase, ...data});

Future<List<double>> _samples(int count, Future<void> Function() invoke) async {
  final values = <double>[];
  for (var i = 0; i < count; i++) {
    final watch = Stopwatch()..start();
    await invoke();
    values.add(watch.elapsedMicroseconds / 1000);
  }
  return values;
}

double _mainCpuMs() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // Runner verifies Android's CLK_TCK == 100 before collecting results.
  return (int.parse(fields[11]) + int.parse(fields[12])) * 10.0;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('MgRead Runtime benchmark'))),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  try {
    final config = await _control('/config') as Map<String, dynamic>;
    await const MethodChannel('mgread_plugin_runtime/android_backend').invokeMethod<void>('select', {'backend': config['backend']});
    await AndroidNodeRuntimeSettings.instance.initialize();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _event('baseline');
    final runtime = PluginRuntime();
    final cold = Stopwatch()..start();
    await runtime.configurePluginHttpProxy(null);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    final startupMs = cold.elapsedMicroseconds / 1000;
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    await _event('startup', {'startupMs': startupMs, 'nodeVersion': ping.nodeVersion, 'runtimeKind': status.runtimeKind});
    if (config['seed'] == true) {
      final bytes = base64Decode(const String.fromEnvironment('MGREAD_BENCH_ARTIFACT_BASE64'));
      final imported = await runtime.importPluginArtifacts(
        [
          (
            artifact: PluginTransferArtifact(
              bytes: bytes.length,
              checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
              pluginId: _plugin,
              version: '1.0.0',
              format: PluginArtifactFormat.singleFile,
              provenance: PluginArtifactProvenance.installed,
              developmentFingerprint: null,
              developmentRevision: null,
            ),
            bytes: Stream.value(bytes),
          ),
        ],
        forceUpgradePluginIds: {_plugin},
      );
      if (imported.single.status != PluginTransferImportStatus.installed) throw StateError('Fixture import failed');
      await runtime.invoke(const SourceDiscoverInvocation(pluginId: _plugin));
      await _event('done', {'seed': true});
      return;
    }
    final first = Stopwatch()..start();
    await runtime.invoke(const SourceDiscoverInvocation(pluginId: _plugin));
    final firstSourceMs = first.elapsedMicroseconds / 1000;
    Future<String> search(String query) async =>
        (await runtime.invoke(SourceSearchInvocation(pluginId: _plugin, query: query, pageSize: 1))).items.single.title;
    Future<void> catalog() async {
      final result = await runtime.invoke(const SourceChaptersInvocation(pluginId: _plugin, id: 'book:0', refresh: true));
      if (result.items.length != 5000) throw StateError('Catalog mismatch');
    }

    Future<void> content() async {
      final result = await runtime.invoke(const SourceContentInvocation(pluginId: _plugin, id: 'book:0', chapterId: 'chapter:0'));
      if (result.text?.length != 49152) throw StateError('Content mismatch');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.write('x' * 4096);
      unawaited(request.response.close());
    });
    var nonce = 0;
    Future<void> http() async {
      if (await search('http:${server.port}:${nonce++}') != '4096') throw StateError('HTTP body mismatch');
    }

    // One warm-up for every measured path; cold module loading is reported above.
    await search('cpu');
    await catalog();
    await content();
    await http();
    final metrics = <String, Object?>{
      'firstSourceMs': firstSourceMs,
      'pingMs': await _samples(50, () async {
        await runtime.invoke(const RuntimePingInvocation());
      }),
      'discoverMs': await _samples(50, () async {
        await runtime.invoke(const SourceDiscoverInvocation(pluginId: _plugin));
      }),
      'cpuJsonMs': await _samples(30, () async {
        await search('cpu');
      }),
      'catalog5000Ms': await _samples(10, catalog),
      'content48KiBMs': await _samples(20, content),
      'localHttp4KiBMs': await _samples(30, http),
    };
    final parallel = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      await Future.wait(List.generate(4, (_) => search('cpu')));
    }
    metrics['parallelCpuOpsPerSecond'] = 40 * 1000000 / parallel.elapsedMicroseconds;
    await _event('warm', metrics);
    final runtimeCpuBefore = jsonDecode(await search('cpuUsage')) as Map<String, dynamic>;
    final mainCpuBefore = _mainCpuMs();
    await _event('stressStart');
    final stress = Stopwatch()..start();
    var cycles = 0;
    while (stress.elapsedMilliseconds < (config['stressSeconds'] as int) * 1000) {
      await search('cpu');
      await catalog();
      await content();
      await http();
      cycles++;
    }
    final wallMs = stress.elapsedMicroseconds / 1000;
    final mainCpuMs = _mainCpuMs() - mainCpuBefore;
    final runtimeCpuAfter = jsonDecode(await search('cpuUsage')) as Map<String, dynamic>;
    final nodeCpuMs =
        ((runtimeCpuAfter['user'] as num) +
            (runtimeCpuAfter['system'] as num) -
            (runtimeCpuBefore['user'] as num) -
            (runtimeCpuBefore['system'] as num)) /
        1000;
    await _event('stressEnd', {'stressCycles': cycles, 'stressWallMs': wallMs, 'mainCpuMs': mainCpuMs, 'nodeCpuMs': nodeCpuMs});
    await Future<void>.delayed(const Duration(seconds: 3));
    await _event('settled');
    await server.close(force: true);
    await _event('done');
  } catch (error, stack) {
    await _event('error', {'error': error.toString(), 'stack': stack.toString()});
  }
}
