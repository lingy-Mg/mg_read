import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerStatefulWidget {
  /// Creates the application shell.
  const MgReadApp({super.key});

  @override
  ConsumerState<MgReadApp> createState() => _MgReadAppState();
}

class _MgReadAppState extends ConsumerState<MgReadApp> {
  void _toggleTheme(Brightness currentBrightness) {
    // Kept as a narrow no-op so callers can remain unchanged while the
    // temporary light-only product mode is active.
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      routerConfig: ref.watch(appRouterProvider),
      builder: (BuildContext context, Widget? child) {
        return AppThemeModeScope(
          themeMode: ThemeMode.light,
          onToggleTheme: _toggleTheme,
          child: _AndroidRuntimeInitializationNotice(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

/// Starts the Runtime only after the first app frame, keeping navigation usable
/// while the Runtime-owned Android adapter copies or reuses its assets.
class _AndroidRuntimeInitializationNotice extends StatefulWidget {
  const _AndroidRuntimeInitializationNotice({required this.child});

  final Widget child;

  @override
  State<_AndroidRuntimeInitializationNotice> createState() =>
      _AndroidRuntimeInitializationNoticeState();
}

class _AndroidRuntimeInitializationNoticeState
    extends State<_AndroidRuntimeInitializationNotice> {
  StreamSubscription<RuntimeInitializationProgress>? _subscription;
  RuntimeInitializationProgress? _progress;
  PluginRuntimeException? _failure;

  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final runtime = PluginRuntime();
    _subscription = runtime.initialization.listen((progress) {
      if (!mounted) return;
      setState(() => _progress = progress);
      if (progress.stage == RuntimeInitializationStage.ready) {
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (mounted && _progress?.stage == RuntimeInitializationStage.ready) {
            setState(() => _progress = null);
          }
        });
      }
    });
    try {
      await runtime.invoke(const RuntimePingInvocation());
    } on PluginRuntimeException catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final failure = _failure;
    if (progress == null && failure == null) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    final message = switch (failure) {
      null => _messageFor(progress!.stage),
      _ => '运行环境初始化失败，请稍后重试',
    };
    return Stack(
      children: <Widget>[
        widget.child,
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Material(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(message),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: failure == null ? progress!.fraction : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _messageFor(RuntimeInitializationStage stage) => switch (stage) {
    RuntimeInitializationStage.assetsCopying => '正在准备运行环境',
    RuntimeInitializationStage.assetsCopied => '运行环境已准备，正在启动',
    RuntimeInitializationStage.assetsReused => '正在启动运行环境',
    RuntimeInitializationStage.nodeStarting => '正在初始化插件与依赖',
    RuntimeInitializationStage.ready => '运行环境已就绪',
  };
}
