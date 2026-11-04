import 'dart:async';
import 'dart:io';
import 'package:mg_read/app/desktop_restart.dart';
import 'package:mg_read/features/local_import/data/local_import_ingress.dart';

import 'package:flutter/widgets.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/local_content_licenses.dart';
import 'package:mg_read/app/source_verification_command.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

Future<void> main(List<String> arguments) async {
  // Wait before Flutter, app databases, or either Runtime is initialized.
  try {
    arguments = await awaitDesktopRestartParent(arguments);
  } on Object {
    exit(4);
  }
  WidgetsFlutterBinding.ensureInitialized();
  // Resolve the desktop host before composing providers. Keep this platform
  // file IO out of bootstrap so its startup surface still mounts immediately.
  if ((Platform.isWindows || Platform.isMacOS) && !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
    await DesktopRuntimeSettings.instance.initialize();
  }
  registerLocalContentLicenses();
  LocalImportIngress.instance.queuePaths(arguments.where((argument) => !argument.startsWith('--')).toList());
  if (Platform.isWindows) await windowManager.ensureInitialized();
  SourceVerificationCommand? verificationCommand;
  try {
    verificationCommand = parseSourceVerificationCommand(arguments);
  } on SourceVerificationRunException {
    exit(4);
  }
  if (verificationCommand != null && !Platform.isWindows && !Platform.isMacOS) exit(4);
  await installSystemProxyHttpOverrides();
  if (verificationCommand == null) {
    await bootstrapMgReadApp();
    return;
  }
  final exitCode = Completer<int>();
  await bootstrapMgReadApp(
    child: SourceVerificationCommandApp(command: verificationCommand, terminateProcess: exitCode.complete),
  );
  // Keep the desktop entrypoint alive until the command widget has finished
  // the full production verification and flushed its console output.
  exit(await exitCode.future);
}
