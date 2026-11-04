import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/import_export/data/android_backup_file_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mg_read/test/android_backup_import');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('streams a SAF backup in bounded chunks and releases its handle', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-saf-import-success-');
    addTearDown(() => directory.delete(recursive: true));
    final expected = Uint8List.fromList(List<int>.generate(900 * 1024 + 19, (index) => index % 241));
    var offset = 0;
    final reads = <int>[];
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickFiles':
          expect(call.arguments, <String, Object?>{'kind': 'backup'});
          return <Object?>[
            <String, Object?>{'token': 'backup-token', 'name': 'data.mgread', 'bytes': expected.length},
          ];
        case 'readChunk':
          final args = call.arguments! as Map<Object?, Object?>;
          expect(args['token'], 'backup-token');
          expect(args['maxBytes'], lessThanOrEqualTo(AndroidBackupFileImporter.maxChunkBytes));
          reads.add(args['maxBytes']! as int);
          final end = (offset + 173 * 1024).clamp(0, expected.length);
          final data = expected.sublist(offset, end);
          offset = end;
          return <String, Object?>{'data': data, 'eof': offset == expected.length};
        case 'release':
          expect(call.arguments, <String, Object?>{'token': 'backup-token'});
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });

    final importer = AndroidBackupFileImporter(channel: channel, temporaryDirectory: () async => directory);
    final path = await importer.pickImportPath();

    expect(path, isNotNull);
    expect(await File(path!).readAsBytes(), expected);
    expect(reads, isNotEmpty);
    expect(calls.last, 'release');
  });

  test('cancellation invalidates and removes the prior temporary plan', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-saf-import-cancel-');
    addTearDown(() => directory.delete(recursive: true));
    var cancelled = false;
    final importer = AndroidBackupFileImporter(channel: channel, temporaryDirectory: () async => directory);
    // A valid zero-byte file reaches EOF in a single native read.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pickFiles') {
        return cancelled
            ? <Object?>[]
            : <Object?>[
                <String, Object?>{'token': 'first', 'bytes': 0},
              ];
      }
      if (call.method == 'readChunk') return <String, Object?>{'data': Uint8List(0), 'eof': true};
      return null;
    });
    final first = await importer.pickImportPath();
    expect(first, isNotNull);
    cancelled = true;
    expect(await importer.pickImportPath(), isNull);
    expect(await File(first!).exists(), isFalse);
  });

  test('rejects declared oversize before reading and releases its token', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-saf-import-limit-');
    addTearDown(() => directory.delete(recursive: true));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickFiles') {
        return <Object?>[
          <String, Object?>{'token': 'large', 'bytes': AndroidBackupFileImporter.maxBackupBytes + 1},
        ];
      }
      return null;
    });
    final importer = AndroidBackupFileImporter(channel: channel, temporaryDirectory: () async => directory);

    await expectLater(importer.pickImportPath(), throwsFormatException);
    expect(calls, <String>['pickFiles', 'release']);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('removes partial output and releases handle after read failure', () async {
    final directory = await Directory.systemTemp.createTemp('mgread-saf-import-read-failure-');
    addTearDown(() => directory.delete(recursive: true));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickFiles':
          return <Object?>[
            <String, Object?>{'token': 'broken', 'bytes': 100},
          ];
        case 'readChunk':
          if (calls.where((method) => method == 'readChunk').length == 1) {
            return <String, Object?>{
              'data': Uint8List.fromList(<int>[1, 2, 3]),
              'eof': false,
            };
          }
          return <String, Object?>{'data': Uint8List(0), 'eof': true};
        case 'release':
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });
    final importer = AndroidBackupFileImporter(channel: channel, temporaryDirectory: () async => directory);

    await expectLater(importer.pickImportPath(), throwsFormatException);
    expect(calls, <String>['pickFiles', 'readChunk', 'readChunk', 'release']);
    expect(await directory.list().isEmpty, isTrue);
  });
}
