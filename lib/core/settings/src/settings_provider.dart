import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings_manager.dart';
import 'settings_status.dart';

/// Application composition must override this provider with an initialized manager.
final appSettingsProvider = Provider<AppSettingsManager>((ref) {
  throw StateError(
    'AppSettingsManager must be provided by the composition root.',
  );
});

final appSettingsStatusProvider = StreamProvider<SettingsStatus>((ref) async* {
  final settings = ref.watch(appSettingsProvider);
  yield settings.status;
  yield* settings.statusChanges;
});
