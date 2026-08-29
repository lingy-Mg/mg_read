/// 子进程异常退出探针；仅由 persistence_record_store_test 启动。
library;

import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) exit(64);
  final root = Directory(arguments[0])..createSync(recursive: true);
  final database = sqlite3.open('${root.path}${Platform.pathSeparator}app_metadata.sqlite');
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA synchronous=NORMAL');
  database.execute('''
    CREATE TABLE IF NOT EXISTS metadata_records (
      record_id TEXT PRIMARY KEY NOT NULL,
      record_kind TEXT NOT NULL,
      scope_kind TEXT NOT NULL,
      scope_id TEXT NOT NULL,
      parent_id TEXT,
      identity_key TEXT,
      order_key TEXT,
      state_key TEXT,
      format_version INTEGER NOT NULL,
      revision INTEGER NOT NULL,
      payload_json TEXT NOT NULL,
      created_at_utc INTEGER NOT NULL,
      updated_at_utc INTEGER NOT NULL
    )
  ''');
  final id = arguments[2];
  if (arguments[1] == 'committed') {
    _insert(database, id);
    stdout.writeln('committed');
    await stdout.flush();
    exit(0);
  }
  if (arguments[1] != 'uncommitted') exit(64);
  database.execute('BEGIN IMMEDIATE');
  _insert(database, id);
  stdout.writeln('uncommitted-ready');
  await stdout.flush();
  await Completer<void>().future;
}

void _insert(Database database, String id) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  database.execute(
    '''INSERT INTO metadata_records (
      record_id, record_kind, scope_kind, scope_id, state_key,
      format_version, revision, payload_json, created_at_utc, updated_at_utc
    ) VALUES (?, 'app_setting', 'local', 'primary', 'active', 2, 1, ?, ?, ?)''',
    <Object?>[id, '{"value":"initial"}', now, now],
  );
}
