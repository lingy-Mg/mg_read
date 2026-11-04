/// Standalone Windows Range media service for the Android prepared Surface run.
/// Start after creating the fixed sample at MGREAD_COMPANION_SAMPLE_PATH.
library;

import 'dart:async';
import 'dart:io';

import '../integration_test/support/companion_native_qa_server.dart';

Future<void> main() async {
  final server = await CompanionNativeQaServer.start();
  // ignore: avoid_print
  print('COMPANION_MEDIA_SERVER_READY port=${CompanionNativeQaServer.coordinatorPort}');
  final stopped = Completer<void>();
  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => stop()),
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => stop()),
  ];
  await stopped.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await server.close();
}
