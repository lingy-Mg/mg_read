import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/import_export/data/android_backup_file_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mg_read/test/android_backup_export');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('creates an SAF document, streams bounded chunks, finalizes success, and removes the temp file', () async {
    final root = await Directory.systemTemp.createTemp('mgread-saf-export-success-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}daily-backup.mgread');
    final expected = Uint8List.fromList(List<int>.generate(900 * 1024 + 19, (index) => index % 239));
    await source.writeAsBytes(expected);
    final writes = <Uint8List>[];
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'createExport':
          expect(call.arguments, <String, Object?>{'fileName': 'daily-backup.mgread', 'mimeType': 'application/octet-stream'});
          return <String, Object?>{'token': 'saf-token'};
        case 'writeChunk':
          final args = call.arguments! as Map<Object?, Object?>;
          expect(args['token'], 'saf-token');
          final bytes = args['data']! as Uint8List;
          writes.add(bytes);
          return null;
        case 'finishExport':
          expect(call.arguments, <String, Object?>{'token': 'saf-token', 'success': true});
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });

    final exported = await AndroidBackupFileExporter(channel: channel).exportFile(source.path);

    expect(exported, isTrue);
    expect(calls.first, 'createExport');
    expect(calls.last, 'finishExport');
    expect(writes, isNotEmpty);
    expect(writes.every((chunk) => chunk.length <= AndroidBackupFileExporter.maxChunkBytes), isTrue);
    expect(writes.expand((chunk) => chunk).toList(), expected);
    expect(await source.exists(), isFalse);
  });

  test('returns false for SAF picker cancellation and removes the temporary file', () async {
    final root = await Directory.systemTemp.createTemp('mgread-saf-export-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}cancelled.mgread');
    await source.writeAsString('backup');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'createExport');
      return null;
    });

    expect(await AndroidBackupFileExporter(channel: channel).exportFile(source.path), isFalse);
    expect(calls, <String>['createExport']);
    expect(await source.exists(), isFalse);
  });

  test('aborts and deletes an incomplete SAF document after a write failure', () async {
    final root = await Directory.systemTemp.createTemp('mgread-saf-export-failure-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}failure.mgread');
    await source.writeAsBytes(List<int>.filled(300 * 1024, 7));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'createExport':
          return <String, Object?>{'token': 'broken-token'};
        case 'writeChunk':
          throw PlatformException(code: 'export_write_failed');
        case 'finishExport':
          expect(call.arguments, <String, Object?>{'token': 'broken-token', 'success': false});
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });

    await expectLater(
      AndroidBackupFileExporter(channel: channel).exportFile(source.path),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'export_write_failed')),
    );
    expect(calls, <String>['createExport', 'writeChunk', 'finishExport']);
    expect(await source.exists(), isFalse);
  });
}
