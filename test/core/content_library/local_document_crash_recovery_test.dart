// Manual crash fixture: run once with MGREAD_CRASH_PHASE=prepare, then again
// against the same MGREAD_CRASH_ROOT with MGREAD_CRASH_PHASE=recover.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  test('local document cold-crash recovery fixture', () async {
    final rootPath = Platform.environment['MGREAD_CRASH_ROOT'];
    final phase = Platform.environment['MGREAD_CRASH_PHASE'];
    if (rootPath == null || (phase != 'prepare' && phase != 'recover')) {
      markTestSkipped('Set MGREAD_CRASH_ROOT and MGREAD_CRASH_PHASE=prepare|recover.');
      return;
    }
    final root = Directory(rootPath);

    if (phase == 'prepare') {
      final library = await ContentLibrary.open(dataRoot: root);
      final bytes = utf8.encode('第一章\n\n子进程已完整准备待确认导入。');
      final prepared = await library.prepareLocalImport(
        LocalImportInput(fileName: 'killed-before-publication.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
      );
      expect(prepared.status, LocalImportStatus.awaitingConfirmation);
      await File('${root.path}${Platform.pathSeparator}crash-fixture-job.txt').writeAsString(prepared.id, flush: true);
      // Deliberately terminate the test VM after durable preparation and leave
      // the database and staging files exactly as process death left them.
      Process.killPid(pid, ProcessSignal.sigkill);
      fail('SIGKILL was not delivered to the fixture process.');
    }

    final marker = File('${root.path}${Platform.pathSeparator}crash-fixture-job.txt');
    expect(marker.existsSync(), isTrue, reason: 'Run the prepare phase first.');
    final jobId = await marker.readAsString();
    final library = await ContentLibrary.open(dataRoot: root);
    try {
      expect(await library.loadShelfProjection(), isEmpty);
      final jobs = await library.localImportJobs();
      final job = jobs.singleWhere((entry) => entry.id == jobId);
      expect(job.status, LocalImportStatus.awaitingConfirmation);
      final retried = await library.commitLocalImport(jobId);
      expect(retried.status, LocalImportStatus.succeeded, reason: retried.errorCode);
      expect(await library.loadShelfProjection(), hasLength(1));
    } finally {
      await library.close();
    }
  });
}
