/// 应用首次展示遮罩。
///
/// 真实路由始终保留在同一棵树中并正常布局、绘制和解码；遮罩隔离触摸与语义。
/// 首页报告首次可见内容就绪后撤下遮罩，不重新挂载路由。失败提供重试和诊断入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';

class AppStartupGate extends ConsumerStatefulWidget {
  const AppStartupGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends ConsumerState<AppStartupGate> {
  AppStartupStatus? _lastStatus;
  bool _shellFrameScheduled = false;
  bool _loadingArmed = false;
  bool _showDiagnostics = false;

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
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: blocked,
              child: ExcludeSemantics(
                excluding: blocked,
                child: TickerMode(
                  enabled: !blocked,
                  child: RepaintBoundary(child: widget.child),
                ),
              ),
            ),
            if (blocked)
              Positioned.fill(
                child: ColoredBox(
                  key: const Key('app-startup-mask'),
                  color: AppThemeTokens.of(context).pageBackground,
                  child: state.isBooting || state.isReady ? _loading() : _failure(context, startup, state),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _loading() => Semantics(
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
            Text('正在准备书架…', style: Theme.of(context).textTheme.bodyMedium),
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
          FilledButton(key: const Key('startup-retry'), onPressed: startup.retry, child: const Text('重试')),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('startup-diagnostics'),
            onPressed: () {
              setState(() => _showDiagnostics = true);
              const DiagnosticsRoute().go(context);
            },
            child: const Text('查看诊断'),
          ),
        ],
      ),
    ),
  );
}
