/// Explicit App diagnostics activation boundary.
///
/// The persisted preference remains in the ordinary settings store. This
/// boundary only starts capture for the current process after a user opt-in;
/// disabling is deliberately a next-launch setting so the active writer can
/// finish and close its one run file safely.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class DiagnosticsActivation {
  bool get enabledForCurrentRun;

  Future<bool> enableForCurrentRun();

  Future<void> disableOnNextLaunch();
}

final diagnosticsActivationProvider = Provider<DiagnosticsActivation?>((ref) => null);
