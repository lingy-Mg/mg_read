/// Shared import coordinator exercised through Android's host-owned staging adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '65 Android sources write files, verify once and finalize once',
    () async {
      final fixture = await _Fixture.create(quarantineLast: true);
      final result = await fixture.runtime.importPluginArtifacts([
        for (var index = 0; index < 65; index++) _input('org.test.$index'),
      ]);
      expect(fixture.events, [
        'plan',
        'begin',
        'verify',
        'finish',
        'list',
        'cancel',
      ]);
      expect(fixture.writtenLengths, List.filled(65, 1));
      expect(
        result.where(
          (item) => item.status == PluginTransferImportStatus.installed,
        ),
        hasLength(64),
      );
      expect(result.last.status, PluginTransferImportStatus.failed);
    },
  );

  test(
    '488865 bytes use the same file protocol without channel chunks',
    () async {
      final fixture = await _Fixture.create();
      final result = await fixture.runtime.importPluginArtifacts([
        _input('org.test.large', bytes: List.filled(488865, 7)),
      ]);
      expect(fixture.writtenLengths, [488865]);
      expect(result.single.status, PluginTransferImportStatus.installed);
      expect(fixture.events.where((event) => event == 'finish'), hasLength(1));
    },
  );

  test(
    'concurrent imports queue planning until the previous catalog is confirmed',
    () async {
      final fixture = await _Fixture.create();
      final unblock = Completer<void>();
      final copying = Completer<void>();
      Stream<List<int>> stalled() async* {
        copying.complete();
        await unblock.future;
        yield [1];
      }

      final first = fixture.runtime.importPluginArtifacts([
        (artifact: _artifact('org.test.same', 1), bytes: stalled()),
      ]);
      await copying.future;
      final second = fixture.runtime.importPluginArtifacts([
        _input('org.test.same'),
      ]);
      final secondExpectation = expectLater(
        second,
        throwsA(
          isA<PluginRuntimeException>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.events, ['plan', 'begin']);
      unblock.complete();
      await first;
      await secondExpectation;
      expect(fixture.events, [
        'plan',
        'begin',
        'verify',
        'finish',
        'list',
        'cancel',
        'plan',
      ]);
    },
  );

  test(
    'write failures remain handled and cancel the batch before another import',
    () async {
      final fixture = await _Fixture.create(blockFile: true);
      await expectLater(
        fixture.runtime.importPluginArtifacts([_input('org.test.failed')]),
        throwsA(
          isA<PluginRuntimeException>().having(
            (e) => e.code,
            'code',
            'file_write_failed',
          ),
        ),
      );
      expect(fixture.events, ['plan', 'begin', 'cancel']);
      fixture.blockFile = false;
      expect(
        (await fixture.runtime.importPluginArtifacts([
          _input('org.test.next'),
        ])).single.status,
        PluginTransferImportStatus.installed,
      );
    },
  );

  test('truncated streams cancel without verification or restart', () async {
    final fixture = await _Fixture.create();
    await expectLater(
      fixture.runtime.importPluginArtifacts([
        (
          artifact: _artifact('org.test.truncated', 2),
          bytes: Stream.value([1]),
        ),
      ]),
      throwsA(
        isA<PluginRuntimeException>().having(
          (e) => e.code,
          'code',
          'plugin_transfer_size_mismatch',
        ),
      ),
    );
    expect(fixture.events, ['plan', 'begin', 'cancel']);
  });
}

PluginTransferArtifact _artifact(String id, int bytes) =>
    PluginTransferArtifact(
      pluginId: id,
      version: '1.0.0',
      bytes: bytes,
      checksum: '00000000',
      format: PluginArtifactFormat.singleFile,
      provenance: PluginArtifactProvenance.installed,
      developmentFingerprint: null,
      developmentRevision: null,
    );

({PluginTransferArtifact artifact, Stream<List<int>> bytes}) _input(
  String id, {
  List<int> bytes = const [1],
}) => (artifact: _artifact(id, bytes.length), bytes: Stream.value(bytes));

final class _Fixture {
  _Fixture(this.root, this.quarantineLast, this.blockFile);
  final Directory root;
  final bool quarantineLast;
  bool blockFile;
  late final PluginRuntime runtime;
  final events = <String>[];
  final writtenLengths = <int>[];
  final installed = <String>{};
  List<Map<Object?, Object?>> artifacts = [];
  List<String> paths = [];
  late Directory directory;
  var sequence = 0;
  static const channel = MethodChannel('mgread_plugin_runtime/android');
  static const progress = MethodChannel(
    'mgread_plugin_runtime/android/progress',
  );

  static Future<_Fixture> create({
    bool quarantineLast = false,
    bool blockFile = false,
  }) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('mgread-import-contract-'),
      quarantineLast,
      blockFile,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(channel, fixture.handle);
    fixture.runtime = PluginRuntime.androidForTesting();
    addTearDown(() async {
      await fixture.runtime.debugDispose();
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(progress, null);
      await fixture.root.delete(recursive: true);
    });
    return fixture;
  }

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>?;
    switch (call.method) {
      case 'invoke':
        final method = args!['method'];
        if (method == 'plugins.transfer.plan.v2') {
          events.add('plan');
          final params = args['params'] as Map;
          final incoming = (params['artifacts'] as List).cast<Map>();
          return jsonEncode({
            'ok': true,
            'result': [
              for (final artifact in incoming)
                {
                  'id': artifact['id'],
                  'version': artifact['version'],
                  'action': installed.contains(artifact['id'])
                      ? 'same'
                      : 'missing',
                  'receiverVersion': installed.contains(artifact['id'])
                      ? '1.0.0'
                      : null,
                },
            ],
          });
        }
        if (method == 'plugins.transfer.verify.v2') {
          events.add('verify');
          final manifest =
              jsonDecode(
                    await File(
                      '${directory.path}/manifest.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(manifest['artifacts'], hasLength(artifacts.length));
          expect(
            (args['params'] as Map)['batchId'],
            sequence.toRadixString(16).padLeft(32, '0'),
          );
          writtenLengths.addAll(
            await Future.wait(paths.map((path) => File(path).length())),
          );
          return jsonEncode({
            'ok': true,
            'result': {'verified': true},
          });
        }
        expect(method, 'plugins.list.v1');
        events.add('list');
        return jsonEncode({
          'ok': true,
          'result': [
            for (var index = 0; index < artifacts.length; index++)
              {
                'id': artifacts[index]['id'],
                'name': 'fixture',
                'displayName': 'fixture',
                'description': '',
                'iconUrl': null,
                'activeVersion': quarantineLast && index == artifacts.length - 1
                    ? null
                    : '1.0.0',
                'pendingVersion': null,
                'enabled': !(quarantineLast && index == artifacts.length - 1),
                'status': quarantineLast && index == artifacts.length - 1
                    ? 'quarantined'
                    : 'active',
                'contentKinds': ['novel'],
                'sourceUrl': null,
              },
          ],
        });
      case 'beginPluginTransferBatch':
        events.add('begin');
        artifacts = (args!['artifacts'] as List).cast<Map<Object?, Object?>>();
        final id = (++sequence).toRadixString(16).padLeft(32, '0');
        directory = await Directory('${root.path}/.batch-$id.part').create();
        paths = [
          for (var index = 0; index < artifacts.length; index++)
            '${directory.path}/$index.mgplugin.js.part',
        ];
        if (blockFile) await Directory(paths.first).create();
        return {'id': id, 'directory': directory.path, 'temporaryPaths': paths};
      case 'finishPluginTransferBatch':
        events.add('finish');
        installed.addAll(artifacts.map((artifact) => artifact['id'] as String));
        return null;
      case 'cancelPluginTransferBatch':
        events.add('cancel');
        if (await directory.exists()) await directory.delete(recursive: true);
        return null;
      case 'dispose':
        return null;
      default:
        fail('Unexpected platform method: ${call.method}');
    }
  }
}
