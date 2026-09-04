part of 'content_library.dart';

/// Bounded local operation notifications backed by app-owned metadata.
///
/// Writes are only scheduled by [ContentLibrary] after a durable bookshelf
/// mutation. Reads and clearing are explicit notification-page work, so the
/// repository adds no startup query or long-lived listener.
final class _LibraryNotificationOperations {
  _LibraryNotificationOperations(this._library);

  final ContentLibrary _library;

  /// Lists newest notifications first after pending non-blocking writes settle.
  Future<List<LibraryNotification>> list({int limit = libraryNotificationMaxCount}) async {
    if (limit < 1 || limit > libraryNotificationMaxCount) {
      throw ArgumentError.value(limit, 'limit');
    }
    await _library._notificationWriteTail;
    final page = await _library._persistence.metadataRecords.list(RecordQuery(recordKind: _notificationKind, scope: _scope, limit: limit));
    return List<LibraryNotification>.unmodifiable(page.records.map(_notificationFromRecord));
  }

  /// Clears the complete bounded local notification history.
  Future<void> clear() async {
    await _library._notificationWriteTail;
    final page = await _library._persistence.metadataRecords.list(
      const RecordQuery(recordKind: _notificationKind, scope: _scope, limit: libraryNotificationMaxCount),
    );
    if (page.records.isNotEmpty) {
      await _library._persistence.metadataRecords.deleteBatch(page.records);
    }
  }

  Future<void> append({required LibraryNotificationKind kind, required String title}) async {
    final boundedTitle = title.trim();
    if (boundedTitle.isEmpty) return;
    final occurredAt = DateTime.now().toUtc();
    final id = _id();
    await _library._persistence.metadataRecords.create(
      RecordDraft(
        id: id,
        recordKind: _notificationKind,
        scope: _scope,
        orderKey: _newestFirstOrderKey(occurredAt),
        stateKey: kind.code,
        document: <String, Object?>{
          'kind': kind.code,
          'title': boundedTitle.length <= 512 ? boundedTitle : boundedTitle.substring(0, 512),
          'occurredAt': occurredAt.toIso8601String(),
        },
      ),
    );
    final retained = await _library._persistence.metadataRecords.list(
      const RecordQuery(recordKind: _notificationKind, scope: _scope, limit: libraryNotificationMaxCount + 1),
    );
    if (retained.records.length > libraryNotificationMaxCount) {
      await _library._persistence.metadataRecords.delete(previous: retained.records.last);
    }
  }
}

LibraryNotification _notificationFromRecord(RecordEnvelope record) {
  final kind = LibraryNotificationKind.fromCode(record.document['kind'] as String? ?? '');
  final title = record.document['title'];
  final occurredAt = DateTime.tryParse(record.document['occurredAt'] as String? ?? '');
  if (kind == null || title is! String || title.isEmpty || occurredAt == null) {
    throw const FormatException('Invalid library notification record.');
  }
  return LibraryNotification(id: record.id, kind: kind, title: title, occurredAt: occurredAt.toLocal());
}

String _newestFirstOrderKey(DateTime occurredAt) {
  const maximumMicros = 9999999999999999;
  final inverted = maximumMicros - occurredAt.microsecondsSinceEpoch;
  return inverted.toString().padLeft(16, '0');
}
