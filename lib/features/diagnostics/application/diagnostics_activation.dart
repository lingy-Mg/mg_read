/// Explicit App diagnostics activation boundary.
///
/// The persisted preference remains in the ordinary settings store. This
/// boundary starts file recording only after opt-in. Disabling closes event
/// admission immediately and drains previously accepted writes before return.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class DiagnosticsActivation {
  bool get enabledForCurrentRun;

  Future<bool> enableForCurrentRun();

  Future<void> disableForCurrentRun();
}

final diagnosticsActivationProvider = Provider<DiagnosticsActivation?>((ref) => null);
