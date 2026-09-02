import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/source_verification_command.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  SourceVerificationCommand? verificationCommand;
  try {
    verificationCommand = parseSourceVerificationCommand(arguments);
  } on SourceVerificationRunException {
    exit(4);
  }
  if (verificationCommand != null && !Platform.isWindows) exit(4);
  await installSystemProxyHttpOverrides();
  if (verificationCommand == null) {
    await bootstrapMgReadApp();
    return;
  }
  final exitCode = Completer<int>();
  await bootstrapMgReadApp(
    child: SourceVerificationCommandApp(command: verificationCommand, terminateProcess: exitCode.complete),
  );
  // A Windows Release build is a GUI-subsystem executable. Keep the Dart
  // entrypoint alive until the command widget has finished the full
  // production verification and flushed its console output.
  exit(await exitCode.future);
}
