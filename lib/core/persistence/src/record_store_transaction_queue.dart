/// PersistenceRecordStore 的事务与在途操作关闭屏障。
///
/// 保持同一 Drift 后台执行器和原有 Zone 重入语义。
part of 'record_store.dart';

extension _PersistenceRecordTransactionQueue on PersistenceRecordStore {
  Future<T> _transaction<T>(Future<T> Function() action) async {
    _ensureOpen();
    return _database.transaction(action);
  }

  void _ensureOpen() {
    if (_closed || (_closing && !identical(Zone.current[#persistenceRecordStore], this))) {
      throw const PersistenceClosedError();
    }
  }

  Future<T> _withOperation<T>(Future<T> Function() action) {
    if (identical(Zone.current[#persistenceRecordStore], this)) {
      return action();
    }
    if (_closed || _closing) {
      return Future<T>.error(const PersistenceClosedError());
    }
    _activeOperations++;
    return runZoned<Future<T>>(
      () => Future<T>.sync(action).whenComplete(() {
        _activeOperations--;
        if (_closing && _activeOperations == 0) {
          _idleOperations?.complete();
        }
      }),
      zoneValues: <Object?, Object?>{#persistenceRecordStore: this},
    );
  }
}
