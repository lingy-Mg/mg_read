/// Windows 正式 App 内置的数据源自检页面。
///
/// 职责：启动单源/全部来源的生产链路检查，展示逐阶段结果并导出 JSON 报告。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Platform.isWindows) _start();
    });
  }

  Future<void> _start() async {
    if (_running) return;
    final token = SourceVerificationCancellationToken();
    setState(() {
      _cancellationToken = token;
      _progress = null;
      _report = null;
      _runErrorCode = null;
      _running = true;
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
      if (mounted) {
        setState(() {
          _running = false;
          _cancellationToken = null;
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
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('source-verification-top-bar'),
                backButtonKey: const Key('source-verification-back'),
                title: widget.pluginId == null ? '检测全部数据源' : '检测数据源',
                onBack: widget.onBackRequested,
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
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!Platform.isWindows) {
      return const _VerificationMessage(
        key: Key('source-verification-windows-only'),
        icon: Icons.desktop_windows_outlined,
        title: '当前仅支持 Windows 检测',
        message: '数据源插件本身保持双端兼容，本次只实现 Windows 正式宿主验证。',
      );
    }
    final report = _report;
    return ListView(
      key: const Key('source-verification-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.section,
      ),
      children: <Widget>[
        _VerificationOverview(running: _running, progress: _progress, report: report, errorCode: _runErrorCode),
        const SizedBox(height: AppSpacing.comfortable),
        if (report != null)
          for (final source in report.sources) ...<Widget>[_SourceResultCard(source: source), const SizedBox(height: AppSpacing.regular)],
        if (_runErrorCode != null)
          _VerificationMessage(
            key: const Key('source-verification-run-failure'),
            icon: Icons.error_outline,
            title: '自检引擎未能启动',
            message: _runErrorMessage(_runErrorCode!),
          ),
        const SizedBox(height: AppSpacing.regular),
        if (_running)
          OutlinedButton.icon(
            key: const Key('source-verification-cancel'),
            onPressed: _cancellationToken?.cancel,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('完成当前请求后停止'),
          )
        else
          FilledButton.icon(
            key: const Key('source-verification-restart'),
            onPressed: _start,
            icon: const Icon(Icons.refresh),
            label: Text(report == null && _runErrorCode == null ? '开始检测' : '重新检测'),
          ),
        const SizedBox(height: AppSpacing.regular),
        Text(
          '检测使用当前 App 的正式 Runtime、网络设置和已启用插件；不会写入书架。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
        ),
      ],
    );
  }
}

class _VerificationOverview extends StatelessWidget {
  const _VerificationOverview({required this.running, required this.progress, required this.report, required this.errorCode});

  final bool running;
  final SourceVerificationProgress? progress;
  final SourceVerificationReport? report;
  final String? errorCode;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final current = progress;
    final title = running
        ? '正在执行全链路检测'
        : report == null
        ? errorCode == null
              ? '准备检测'
              : '检测未启动'
        : report!.isSuccessful
        ? '全部检测通过'
        : '检测完成，存在异常';
    final message = running && current != null
        ? '${current.displayName} · ${_stageLabel(current.stage)}'
        : report == null
        ? '将依次检查 Runtime、发现、搜索、详情、目录、正文和资源代理。'
        : '通过 ${report!.passedCount}，失败 ${report!.failedCount}，需人工操作 ${report!.interactionRequiredCount}。';
    return DecoratedBox(
      key: const Key('source-verification-overview'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (running)
              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            else
              Icon(report?.isSuccessful == true ? Icons.verified_outlined : Icons.fact_check_outlined, color: tokens.dataSourceAccent),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceResultCard extends StatelessWidget {
  const _SourceResultCard({required this.source});

  final SourceVerificationSourceResult source;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final passed = source.status == SourceVerificationResultStatus.passed;
    return DecoratedBox(
      key: ValueKey<String>('source-verification-result-${source.pluginId}'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: passed ? tokens.dataSourceAccent.withValues(alpha: 0.45) : tokens.notification.withValues(alpha: 0.55)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  passed ? Icons.check_circle_outline : Icons.error_outline,
                  color: passed ? tokens.dataSourceAccent : tokens.notification,
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(child: Text(source.displayName, style: Theme.of(context).textTheme.titleMedium)),
                Text(_sourceStatusLabel(source.status), style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: AppSpacing.regular),
            for (final stage in source.stages)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.unit),
                child: Row(
                  children: <Widget>[
                    Icon(_stageIcon(stage.status), size: 18, color: _stageColor(tokens, stage.status)),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(child: Text(_stageLabel(stage.stage))),
                    Text(
                      stage.code == null ? _stageStatusLabel(stage.status) : '${_stageStatusLabel(stage.status)} · ${stage.code}',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VerificationMessage extends StatelessWidget {
  const _VerificationMessage({required this.icon, required this.title, required this.message, super.key});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.section),
    child: Column(
      children: <Widget>[
        Icon(icon, size: 40),
        const SizedBox(height: AppSpacing.regular),
        Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.unit),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

String _stageLabel(String stage) {
  if (stage.startsWith('content.')) return '首、中、末内容';
  return switch (stage) {
    'runtime' => 'Runtime 与插件状态',
    'discover' => '发现',
    'search' => '搜索',
    'detail' => '详情',
    'chapters' => '完整目录',
    'content' => '首、中、末内容',
    'resource.cover' => '封面资源',
    'resource.content' => '正文或媒体资源',
    _ => '数据源检查',
  };
}

String _sourceStatusLabel(SourceVerificationResultStatus status) => switch (status) {
  SourceVerificationResultStatus.passed => '通过',
  SourceVerificationResultStatus.failed => '失败',
  SourceVerificationResultStatus.interactionRequired => '需要人工操作',
  SourceVerificationResultStatus.cancelled => '已取消',
};

String _stageStatusLabel(SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => '通过',
  SourceVerificationStageStatus.failed => '失败',
  SourceVerificationStageStatus.skipped => '跳过',
  SourceVerificationStageStatus.cancelled => '已取消',
};

IconData _stageIcon(SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => Icons.check_circle_outline,
  SourceVerificationStageStatus.failed => Icons.cancel_outlined,
  SourceVerificationStageStatus.skipped => Icons.remove_circle_outline,
  SourceVerificationStageStatus.cancelled => Icons.stop_circle_outlined,
};

Color _stageColor(AppThemeTokens tokens, SourceVerificationStageStatus status) => switch (status) {
  SourceVerificationStageStatus.passed => tokens.dataSourceAccent,
  SourceVerificationStageStatus.failed => tokens.notification,
  SourceVerificationStageStatus.skipped || SourceVerificationStageStatus.cancelled => tokens.mutedText,
};

String _runErrorMessage(String code) => switch (code) {
  'runtime_timeout' => 'Runtime 初始化超时，请检查 Node 状态后重试。',
  'source_list_empty' => '当前没有可检测的已启用数据源。',
  'source_not_found' => '该数据源未启用、未激活或已经移除。',
  _ => '自检引擎出现内部错误，请查看应用诊断后重试。',
};

void _ignore() {}
