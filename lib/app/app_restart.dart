/// App-owned cold restart. Flush settings before the Android Activity handoff
/// or desktop successor launch; the next process reads the chosen JS backend.
library;

import 'dart:io';
import 'desktop_restart.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/settings/settings.dart';

final appRestartProvider = Provider<Future<void> Function()>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return () async {
    await settings.flush();
    if (Platform.isWindows || Platform.isMacOS) {
      await restartDesktopApp();
      return;
    }
    await const MethodChannel('mgread/app_lifecycle').invokeMethod<void>('restart');
  };
});
