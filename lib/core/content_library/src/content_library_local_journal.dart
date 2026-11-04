/// Retention for transient import attempts, separate from immutable generations.
/// Recent attempts remain retryable; obsolete staging never owns a live book.
part of 'content_library.dart';

extension _LocalImportJournalRetention on ContentLibrary {
  Future<void> _pruneLocalImportJournal() {
    final action = _localJournalTail.then((_) async {
      final page = await _persistence.metadataRecords.list(const RecordQuery(recordKind: 'local_import_job', scope: _scope, limit: 1000));
      final rows = page.records.toList()
        ..sort((a, b) {
          final aPending = !['succeeded', 'cancelled', 'failed'].contains(a.document['status']);
          final bPending = !['succeeded', 'cancelled', 'failed'].contains(b.document['status']);
          if (aPending != bPending) return aPending ? -1 : 1;
          return (b.document['updatedAt']! as String).compareTo(a.document['updatedAt']! as String);
        });
      final now = DateTime.now().toUtc();
      var retained = 0;
      for (final row in rows) {
        if (_localImports.containsKey(row.id)) {
          retained++;
          continue;
        }
        final job = Map<String, Object?>.from(row.document);
        final age = now.difference(DateTime.parse(job['updatedAt']! as String));
        final terminal = ['succeeded', 'cancelled', 'failed'].contains(job['status']);
        if (terminal && (retained >= 100 || age > const Duration(days: 7))) {
          await _persistence.metadataRecords.delete(previous: row);
          await _localFiles.removeStaging(row.id);
          continue;
        }
        retained++;
        if (job['status'] == 'awaitingConfirmation' && age > const Duration(hours: 24)) {
          job.addAll({'status': 'needsAction', 'errorCode': 'reselect_file'});
          await _saveLocalJob(job);
          await _localFiles.removeStaging(row.id);
        }
      }
    });
    // A failed maintenance attempt must not poison the next retry.
    _localJournalTail = action.catchError((Object _) {});
    return action;
  }
}
