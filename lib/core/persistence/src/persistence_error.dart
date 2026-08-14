sealed class PersistenceError implements Exception {
  const PersistenceError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PersistenceError($code)';
}

final class PersistenceValidationError extends PersistenceError {
  const PersistenceValidationError(String message)
    : super('invalid_document', message);
}

final class PersistenceConflictError extends PersistenceError {
  const PersistenceConflictError()
    : super('revision_conflict', 'The record was changed by another writer.');
}

final class PersistenceFutureVersionError extends PersistenceError {
  const PersistenceFutureVersionError()
    : super(
        'future_document_version',
        'The record is newer than this application supports.',
      );
}

final class PersistenceCorruptionError extends PersistenceError {
  const PersistenceCorruptionError()
    : super('corrupt_document', 'The persisted document is invalid.');
}

final class PersistenceClosedError extends PersistenceError {
  const PersistenceClosedError()
    : super('store_closed', 'The record store is closed.');
}
