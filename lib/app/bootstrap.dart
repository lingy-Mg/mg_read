import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app.dart';

/// Starts the Flutter host composition root.
///
/// This boundary owns framework initialization and the application ProviderScope.
/// Feature, persistence, and Runtime work must be supplied through explicit
/// providers; this function must not eagerly start the Node Runtime or perform
/// database, file, or network work on the UI isolate.
void bootstrapMgReadApp() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MgReadApp()));
}
