import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerStatefulWidget {
  /// Creates the application shell.
  const MgReadApp({super.key, this.themeMode = ThemeMode.system});

  /// The initial visual mode; settings persistence will provide this later.
  final ThemeMode themeMode;

  @override
  ConsumerState<MgReadApp> createState() => _MgReadAppState();
}

class _MgReadAppState extends ConsumerState<MgReadApp> {
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.themeMode;
  }

  @override
  void didUpdateWidget(covariant MgReadApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.themeMode != oldWidget.themeMode) {
      _themeMode = widget.themeMode;
    }
  }

  void _toggleTheme(Brightness currentBrightness) {
    setState(() {
      _themeMode = currentBrightness == Brightness.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      routerConfig: ref.watch(appRouterProvider),
      builder: (BuildContext context, Widget? child) {
        return AppThemeModeScope(
          themeMode: _themeMode,
          onToggleTheme: _toggleTheme,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
