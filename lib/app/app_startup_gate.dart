/// 应用首次展示遮罩。
///
/// 真实路由始终保留在同一棵树中并正常布局、绘制和解码；遮罩隔离触摸与语义。
/// 首页报告首次可见内容就绪后撤下遮罩，不重新挂载路由。失败提供重试和诊断入口。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';

class AppStartupGate extends ConsumerStatefulWidget {
  const AppStartupGate({required this.child, this.waitWarningDelay = const Duration(seconds: 30), super.key});

  final Widget child;
  final Duration waitWarningDelay;

  @override
  ConsumerState<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends ConsumerState<AppStartupGate> {
  AppStartupStatus? _lastStatus;
  bool _shellFrameScheduled = false;
  bool _loadingArmed = false;
  bool _showDiagnostics = false;
  bool _waitWarning = false;
  bool _wasBlocked = true;
  final FocusScopeNode _contentFocus = FocusScopeNode(debugLabel: 'startup-content');
  Timer? _waitDeadline;

  void _armWaitDeadline(AppStartupController startup) {
    _waitDeadline ??= Timer(widget.waitWarningDelay, () {
      if (!mounted || startup.isClosed || startup.isInteractive) return;
      startup.recordStage(startup.activePhase.name, resultState: 'timeout', errorCode: 'startup_wait_timeout');
      setState(() => _waitWarning = true);
    });
  }

  @override
  void dispose() {
    _waitDeadline?.cancel();
    _contentFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startup = ref.watch(appStartupControllerProvider);
    return ValueListenableBuilder<AppStartupState>(
      valueListenable: startup,
      builder: (context, state, child) {
        final previous = _lastStatus;
        _lastStatus = state.status;
        if (state.isBooting && previous == AppStartupStatus.retryableFailure) {
          _showDiagnostics = false;
          _waitWarning = false;
          _waitDeadline?.cancel();
          _waitDeadline = null;
          _shellFrameScheduled = false;
          _loadingArmed = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref.invalidate(libraryPageControllerProvider);
            ref.invalidate(privateLibraryPageControllerProvider);
          });
        }
        if (!_shellFrameScheduled) {
          _shellFrameScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || startup.isClosed) return;
            startup.recordShellFirstFrame(resultState: state.status.name);
            if (!startup.isInteractive) setState(() => _loadingArmed = true);
          });
        }
        final blocked = !startup.isInteractive && !_showDiagnostics;
        if (_wasBlocked && !blocked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_wasBlocked) _contentFocus.nextFocus();
          });
        }
        _wasBlocked = blocked;
        if (blocked && state.status != AppStartupStatus.retryableFailure) {
          _armWaitDeadline(startup);
        } else {
          _waitDeadline?.cancel();
          _waitDeadline = null;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: blocked,
              child: ExcludeSemantics(
                excluding: blocked,
                child: FocusScope(
                  node: _contentFocus,
                  child: ExcludeFocus(
                    excluding: blocked,
                    // Route animations must progress while waiting for their frame.
                    child: RepaintBoundary(child: widget.child),
                  ),
                ),
              ),
            ),
            if (blocked)
              Positioned.fill(
                child: ColoredBox(
                  key: const Key('app-startup-mask'),
                  color: AppThemeTokens.of(context).pageBackground,
                  child: state.status == AppStartupStatus.retryableFailure
                      ? _failure(context, startup, state)
                      : _waitWarning
                      ? _waiting(context, startup)
                      : _loading(startup),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _loading(AppStartupController startup) => Semantics(
    label: '正在准备书架',
    liveRegion: true,
    child: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_stories_rounded, size: 48),
            const SizedBox(height: AppSpacing.comfortable),
            Text('MgRead', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.section),
            SizedBox(width: 24, height: 24, child: _loadingArmed ? const CircularProgressIndicator(strokeWidth: 2) : null),
            const SizedBox(height: AppSpacing.regular),
            Text(startup.activePhase.label, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    ),
  );

  void _openDiagnostics() {
    setState(() => _showDiagnostics = true);
    const DiagnosticsRoute().go(context);
  }

  Widget _waiting(BuildContext context, AppStartupController startup) => Material(
    color: Colors.transparent,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('启动耗时较长'),
            const SizedBox(height: 12),
            Text(startup.activePhase.label),
            const SizedBox(height: 16),
            FilledButton(
              autofocus: true,
              key: const Key('startup-continue-waiting'),
              onPressed: () {
                setState(() => _waitWarning = false);
                _waitDeadline = null;
                _armWaitDeadline(startup);
              },
              child: const Text('继续等待'),
            ),
            TextButton(onPressed: _openDiagnostics, child: const Text('查看诊断')),
          ],
        ),
      ),
    ),
  );

  Widget _failure(BuildContext context, AppStartupController startup, AppStartupState state) => Material(
    color: Colors.transparent,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('启动失败'),
          const SizedBox(height: 8),
          const Text('startup_failed'),
          const SizedBox(height: 8),
          Text('诊断代码：${state.errorCode ?? 'startup_failed'}'),
          const SizedBox(height: 16),
          FilledButton(autofocus: true, key: const Key('startup-retry'), onPressed: startup.retry, child: const Text('重试')),
          const SizedBox(height: 8),
          TextButton(key: const Key('startup-diagnostics'), onPressed: _openDiagnostics, child: const Text('查看诊断')),
        ],
      ),
    ),
  );
}
