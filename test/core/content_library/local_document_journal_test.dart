import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';

void main() {
  test('cold import journal expires previews and bounds terminal history without creating books', () async {
    final root = await Directory.systemTemp.createTemp('mgread-local-journal-');
    final persistence = await AppPersistence.open(dataRoot: root, registry: RecordDocumentRegistry(contentLibraryRecordDocumentCodecs));
    final library = ContentLibrary.fromPersistence(persistence);
    addTearDown(() async {
      await library.close();
      await persistence.close();
      await root.delete(recursive: true);
    });
    const scope = ScopeKey(kind: 'content_library', id: 'default');
    final now = DateTime.now().toUtc();
    final writes = <RecordDocumentWrite>[];
    for (var i = 0; i < 110; i++) {
      final id = 'task-${i.toString().padLeft(16, '0')}';
      writes.add(
        RecordDocumentWrite(
          id: id,
          recordKind: 'local_import_job',
          expectedRevision: null,
          scope: scope,
          document: LocalImportSnapshot(
            id: id,
            fileName: 'done.txt',
            status: LocalImportStatus.succeeded,
            updatedAt: i < 10 ? now.subtract(const Duration(days: 8)) : now.subtract(Duration(minutes: i)),
          ).toJson(),
        ),
      );
    }
    const previewId = 'preview-expired-1234';
    writes.add(
      RecordDocumentWrite(
        id: previewId,
        recordKind: 'local_import_job',
        expectedRevision: null,
        scope: scope,
        document: LocalImportSnapshot(
          id: previewId,
          fileName: 'pending.txt',
          status: LocalImportStatus.awaitingConfirmation,
          updatedAt: now.subtract(const Duration(hours: 25)),
        ).toJson(),
      ),
    );
    await persistence.metadataRecords.writeDocumentsCas(writes);
    final staged = File('${root.path}/files/local-documents/staging/$previewId/source');
    await staged.parent.create(recursive: true);
    await staged.writeAsString('expired preview');
    final jobs = await library.localImportJobs();
    final preview = jobs.singleWhere((job) => job.id == previewId);
    expect(preview.status, LocalImportStatus.needsAction);
    expect(preview.errorCode, 'reselect_file');
    expect(await staged.exists(), isFalse);
    expect(jobs.length, lessThanOrEqualTo(100));
    expect(
      (await persistence.metadataRecords.list(const RecordQuery(recordKind: 'local_import_job', scope: scope, limit: 1000))).records.length,
      lessThanOrEqualTo(100),
    );
    expect(await library.loadShelfProjection(), isEmpty);
  });
}
