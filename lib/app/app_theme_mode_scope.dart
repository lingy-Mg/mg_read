import 'package:flutter/material.dart';

/// Exposes the temporary, app-session theme control to routed UI.
///
/// This scope deliberately owns no persistence. A future settings delivery can
/// replace the callback with a persisted preference without coupling feature
/// widgets to a settings store.
class AppThemeModeScope extends InheritedWidget {
  /// Creates an app-local theme control scope.
  const AppThemeModeScope({
    required this.themeMode,
    required this.onToggleTheme,
    required super.child,
    super.key,
  });

  /// The mode configured at the application root.
  final ThemeMode themeMode;

  /// Toggles from the effective [Brightness] currently rendered by the UI.
  final ValueChanged<Brightness> onToggleTheme;

  /// Reads the nearest scope installed by [MgReadApp].
  static AppThemeModeScope of(BuildContext context) {
    final AppThemeModeScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppThemeModeScope>();
    assert(
      scope != null,
      'AppThemeModeScope must wrap the routed application.',
    );
    return scope!;
  }

  @override
  bool updateShouldNotify(AppThemeModeScope oldWidget) {
    return themeMode != oldWidget.themeMode;
  }
}
