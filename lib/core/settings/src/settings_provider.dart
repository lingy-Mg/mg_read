import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings_manager.dart';

/// Application composition must override this provider with an initialized manager.
final appSettingsProvider = Provider<AppSettingsManager>((ref) {
  throw StateError(
    'AppSettingsManager must be provided by the composition root.',
  );
});
