/// App-owned cold restart. Flush host settings before handing off to Android;
/// the separate restart Activity replaces the process and its Node VM.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/settings/settings.dart';

final appRestartProvider = Provider<Future<void> Function()>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return () async {
    await settings.flush();
    await const MethodChannel('mgread/app_lifecycle').invokeMethod<void>('restart');
  };
});
