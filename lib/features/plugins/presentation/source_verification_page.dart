/// desktop 正式 App 内置的数据源自检页面。
///
/// 职责：持有一次检测会话，展示实时阶段和结果，确认退出并取消 Runtime 请求。
/// 生命周期：返回、停止和 dispose 共用取消令牌；完成后保留本轮报告供筛选与导出。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

part 'source_verification_widgets.dart';

class SourceVerificationPage extends ConsumerStatefulWidget {
  const SourceVerificationPage({required this.onBackRequested, this.pluginId, super.key});

  final String? pluginId;
  final VoidCallback onBackRequested;

  @override
  ConsumerState<SourceVerificationPage> createState() => _SourceVerificationPageState();
}

class _SourceVerificationPageState extends ConsumerState<SourceVerificationPage> {
  SourceVerificationCancellationToken? _cancellationToken;
  SourceVerificationProgress? _progress;
  SourceVerificationReport? _report;
  String? _runErrorCode;
  bool _running = false;
  bool _exporting = false;
  bool _stopping = false;
  bool _confirmingExit = false;
  bool _leaving = false;
  Completer<void>? _runFinished;
  _ResultFilter _filter = _ResultFilter.all;

  @override
  void dispose() {
    _cancellationToken?.cancel();
    super.dispose();
  }

  void _stop() {
    if (!_running || _stopping) return;
    setState(() => _stopping = true);
    _cancellationToken?.cancel();
  }

  Future<void> _requestBack() async {
    if (_confirmingExit || _leaving) return;
    if (_running) {
      _confirmingExit = true;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('中断检测并退出？'),
          content: const Text('当前检测尚未完成。退出将中断正在进行的请求，并停止后续检测。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('继续检测')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('中断并退出')),
          ],
        ),
      );
      _confirmingExit = false;
      if (!mounted || confirmed != true) return;
      _stop();
      await _runFinished?.future;
      if (!mounted) return;
    }
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) widget.onBackRequested();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _supportsDesktopVerification) _start();
    });
  }

  Future<void> _start() async {
    if (_running) return;
    final token = SourceVerificationCancellationToken();
    final finished = Completer<void>();
    _runFinished = finished;
    setState(() {
      _cancellationToken = token;
      _progress = null;
      _report = null;
      _runErrorCode = null;
      _running = true;
      _stopping = false;
      _filter = _ResultFilter.all;
    });
    try {
      final report = await ref
          .read(sourceVerificationEngineProvider)
          .run(
            pluginId: widget.pluginId,
            cancellationToken: token,
            onProgress: (progress) {
              if (!mounted) return;
              setState(() => _progress = progress);
            },
          );
      if (!mounted) return;
      setState(() => _report = report);
    } on SourceVerificationRunException catch (error) {
      if (!mounted) return;
      setState(() => _runErrorCode = error.code);
    } on Object {
      if (!mounted) return;
      setState(() => _runErrorCode = 'internal');
    } finally {
      if (!finished.isCompleted) finished.complete();
      if (mounted) {
        setState(() {
          _running = false;
          _cancellationToken = null;
          _stopping = false;
        });
      }
    }
  }

  Future<void> _exportReport() async {
    final report = _report;
    if (report == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'JSON 报告', extensions: <String>['json']),
        ],
        suggestedName: 'mgread-source-verification.json',
        confirmButtonText: '导出',
      );
      if (location == null) return;
      await const SourceVerificationReportWriter().write(location.path, report);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源检测报告已导出。')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('报告导出失败，请更换保存位置后重试。')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running || _leaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestBack());
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: AppSecondaryPageContent(
            child: Column(
              children: <Widget>[
                AppSecondaryPageTopBar(
                  headerKey: const Key('source-verification-top-bar'),
                  backButtonKey: const Key('source-verification-back'),
                  title: widget.pluginId == null ? '检测全部数据源' : '检测数据源',
                  onBack: _requestBack,
                  actions: <Widget>[
                    if (_report != null)
                      AppSecondaryPageIconButton(
                        key: const Key('source-verification-export'),
                        label: '导出报告',
                        icon: Icons.file_download_outlined,
                        onPressed: _exporting ? _ignore : _exportReport,
                      ),
                  ],
                ),
                Expanded(child: _buildBody(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!_supportsDesktopVerification) {
      return const _VerificationMessage(
        key: Key('source-verification-desktop-only'),
        icon: Icons.desktop_windows_outlined,
        title: '当前仅支持桌面端检测',
        message: '请在 Windows 或 macOS 正式宿主中运行数据源全链路检测。',
      );
    }
    final report = _report;
    final completed = report?.sources ?? _progress?.completedSources ?? const <SourceVerificationSourceResult>[];
    final visible = completed
        .where(
          (source) => switch (_filter) {
            _ResultFilter.all => true,
            _ResultFilter.issues =>
              source.status == SourceVerificationResultStatus.failed || source.status == SourceVerificationResultStatus.interactionRequired,
            _ResultFilter.passed => source.status == SourceVerificationResultStatus.passed,
          },
        )
        .toList(growable: false);
    final current = _progress;
    final active = _running && current != null && !completed.any((source) => source.pluginId == current.pluginId);
    return ListView(
      key: const Key('source-verification-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.section,
      ),
      children: [
        _VerificationOverview(running: _running, stopping: _stopping, progress: current, report: report, errorCode: _runErrorCode),
        const SizedBox(height: AppSpacing.regular),
        Wrap(
          spacing: AppSpacing.regular,
          runSpacing: AppSpacing.unit,
          children: [
            if (_running)
              OutlinedButton.icon(
                key: const Key('source-verification-cancel'),
                onPressed: _stopping ? null : _stop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(_stopping ? '正在中断…' : '中断检测'),
              )
            else
              FilledButton.icon(
                key: const Key('source-verification-restart'),
                onPressed: _start,
                icon: const Icon(Icons.refresh),
                label: const Text('重新检测'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.comfortable),
        if (_runErrorCode != null)
          _VerificationMessage(
            key: const Key('source-verification-run-failure'),
            icon: Icons.error_outline,
            title: _runErrorCode == 'source_list_empty' ? '暂无可检测的数据源' : '无法开始检测',
            message: _runErrorMessage(_runErrorCode!),
          ),
        if (active) ...[
          Text('当前检测', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.regular),
          _SourceResultCard(
            source: SourceVerificationSourceResult(
              pluginId: current.pluginId,
              displayName: current.displayName,
              version: '',
              status: SourceVerificationResultStatus.passed,
              duration: Duration.zero,
              stages: current.stages,
            ),
            activeStage: current.running ? current.stage : 'next',
          ),
          const SizedBox(height: AppSpacing.comfortable),
        ],
        if (completed.isNotEmpty) ...[
          Text('检测结果 · ${completed.length}', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.regular),
          Wrap(
            spacing: AppSpacing.unit,
            runSpacing: AppSpacing.unit,
            children: [
              for (final filter in _ResultFilter.values)
                ChoiceChip(
                  label: Text(switch (filter) {
                    _ResultFilter.all => '全部',
                    _ResultFilter.issues => '异常 / 待处理',
                    _ResultFilter.passed => '通过',
                  }),
                  selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.regular),
          if (visible.isEmpty) const Padding(padding: EdgeInsets.all(AppSpacing.comfortable), child: Text('暂无符合条件的结果')),
          for (final source in visible) ...[_SourceResultCard(source: source), const SizedBox(height: AppSpacing.regular)],
        ],
        const SizedBox(height: AppSpacing.comfortable),
        Text('检测范围', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.unit),
        Text(
          '使用当前网络设置，依次检查已启用数据源的发现、搜索、详情、完整目录、内容抽样及封面和内容资源。跳过的项目不代表验证通过；视频资源可访问不代表实际播放成功。检测不会写入书架。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
        ),
      ],
    );
  }
}

enum _ResultFilter { all, issues, passed }

bool get _supportsDesktopVerification => Platform.isWindows || Platform.isMacOS;
