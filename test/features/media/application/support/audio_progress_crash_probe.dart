/// Child-process probe for audio_progress_process_restart_test. It commits one
/// complete audio position, starts the next transaction, then waits to be killed
/// without closing SQLite. Only the test's temporary library is touched.
library;

import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) exit(64);
  final database = sqlite3.open('${arguments[0]}${Platform.pathSeparator}app_metadata.sqlite');
  database.execute('PRAGMA journal_mode=WAL');
  database.execute('PRAGMA synchronous=NORMAL');
  void update(String chapter, int milliseconds) => database.execute(
    '''UPDATE reading_progress SET chapter_id = ?, playback_ms = ?
      WHERE item_pk = (SELECT item_pk FROM library_items WHERE item_id = ?)''',
    <Object?>[chapter, milliseconds, arguments[1]],
  );
  update('chapter-2', 60000);
  if (database.updatedRows != 1) exit(65);
  database.execute('BEGIN IMMEDIATE');
  update('chapter-3', 71000);
  stdout.writeln('audio-uncommitted-ready:$pid');
  await stdout.flush();
  await Completer<void>().future;
}
