/// Diagnostic opt-in run-file lifecycle tests.
///
/// These tests use temporary directories only. They verify that startup keeps
/// history cold, one enabled process owns one file, and metadata maintenance
/// never needs to deserialize historical events.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/src/diagnostics_persistence.dart';

import 'diagnostics_testkit.dart';

void main() {
  test('enabled launches own one file each and reopen does not read corrupted history', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-run-files-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final first = await AppDiagnosticsService.open(
      dataRoot: root,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: FixedDiagnosticClock(),
      buildMode: 'test',
      platform: 'windows-test',
    );
    first.manager.emit(
      AppDiagnosticEvents.routeChanged,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
    );
    await first.close();

    final eventRoot = Directory('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}events');
    final firstFile = (await eventRoot.list().where((entity) => entity is File).cast<File>().toList()).single;
    await firstFile.writeAsString('{"broken":true}', mode: FileMode.append);

    final second = await AppDiagnosticsService.open(
      dataRoot: root,
      idGenerator: SequentialDiagnosticIdGenerator(initialValue: 100000),
      clock: FixedDiagnosticClock(initialMicros: 1800000000000000),
      buildMode: 'test',
      platform: 'windows-test',
      deferStartupMaintenance: true,
    );
    addTearDown(second.close);

    final files = await second.listLogFiles();
    expect(files, hasLength(2));
    expect(files.where((file) => file.isCurrent), hasLength(1));
    expect(await eventRoot.list().where((entity) => entity is File).length, 2);

    final current = files.singleWhere((file) => file.isCurrent);
    expect((await second.listLogEvents(current.fileId)).items, isNotEmpty);
    final history = files.singleWhere((file) => !file.isCurrent);
    await expectLater(second.listLogEvents(history.fileId), throwsFormatException);

    final exported = await second.exportLogFile(current.fileId);
    expect(exported.sessionCount, 1);
    expect(
      await File('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}${exported.relativeObjectKey}').exists(),
      isTrue,
    );
    await second.deleteLogFile(history.fileId);
    expect(await second.listLogFiles(), hasLength(1));
  });

  test('metadata listing stays cold across a large file inventory', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-cold-inventory-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final events = Directory('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}events');
    await events.create(recursive: true);
    for (var index = 0; index < 1000; index += 1) {
      await File('${events.path}${Platform.pathSeparator}run-legacy_${index.toString().padLeft(16, '0')}.txt').writeAsString('not-json');
    }

    final store = await DiagnosticsPersistence.open(dataRoot: root);
    addTearDown(store.close);
    expect(store.lastEncoderWorkerIsolateIdForTest, isNull);
    expect(await store.listLogFiles(), hasLength(1000));
    expect(store.lastEncoderWorkerIsolateIdForTest, isNull);
  });

  test('disabled-launch cold archive lists history without creating a diagnostics service', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-disabled-cold-archive-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final diagnosticsRoot = Directory('${root.path}${Platform.pathSeparator}diagnostics');
    final archive = ColdDiagnosticsLogArchive(() async => root);

    expect(await diagnosticsRoot.exists(), isFalse);
    expect(await archive.listLogFiles(), isEmpty);
    expect(await diagnosticsRoot.exists(), isFalse);

    final events = Directory('${diagnosticsRoot.path}${Platform.pathSeparator}events');
    await events.create(recursive: true);
    final corrupt = File('${events.path}${Platform.pathSeparator}run-00000000000000000001-disabled.txt');
    await corrupt.writeAsString('raw-corrupt-log');

    final files = await archive.listLogFiles();
    expect(files, hasLength(1));
    expect(files.single.isCurrent, isFalse);
    await expectLater(archive.listLogEvents(files.single.fileId), throwsFormatException);

    final exported = await archive.exportLogFile(files.single.fileId);
    expect(exported.eventCount, 0);
    expect(await File('${diagnosticsRoot.path}${Platform.pathSeparator}${exported.relativeObjectKey}').readAsString(), 'raw-corrupt-log');
    await archive.deleteLogFile(files.single.fileId);
    expect(await archive.listLogFiles(), isEmpty);
  });

  test('retention deletes cold logs from file metadata without decoding them', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-metadata-retention-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final events = Directory('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}events');
    await events.create(recursive: true);
    for (var index = 0; index < 4; index += 1) {
      final file = File('${events.path}${Platform.pathSeparator}run-old_${index.toString().padLeft(16, '0')}.txt');
      await file.writeAsString('intentionally-not-json-${List<String>.filled(4096, 'x').join()}');
      await file.setLastModified(DateTime.utc(2020, 1, index + 1));
    }

    final store = await DiagnosticsPersistence.open(dataRoot: root, clock: () => DateTime.utc(2026, 8, 30));
    addTearDown(store.close);
    final result = await store.enforceRetention(const DiagnosticRetentionPolicy(regularEventAge: Duration(days: 3)));

    expect(result.deletedSessions, 4);
    expect(await store.listLogFiles(), isEmpty);
    expect(store.lastEncoderWorkerIsolateIdForTest, isNull);
  });
}
