/// Windows 正式可执行文件的数据源自检命令入口。
///
/// 职责：解析生产参数、在真实 ProviderScope 中调用内置自检引擎、写 JSON 报告并返回稳定退出码。
/// 注意：这不是 Flutter 测试入口；CLI 与可见页面复用同一个生产 SourceVerificationEngine。
/// 显式 CLI 测试模式会把完整解码结果和原始异常写到 stdout，便于定位来源问题；这些内容不进入常规诊断流。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

typedef SourceVerificationProcessTerminator = void Function(int exitCode);

final class SourceVerificationCommand {
  const SourceVerificationCommand({required this.pluginId, required this.reportPath});

  final String? pluginId;
  final String reportPath;

  bool get all => pluginId == null;
}

SourceVerificationCommand? parseSourceVerificationCommand(List<String> arguments, {String? currentDirectory}) {
  final active = arguments.any(
    (argument) => argument == '--source-check-all' || argument == '--source-check' || argument.startsWith('--source-check='),
  );
  if (!active) return null;
  String? pluginId;
  String? reportPath;
  var all = false;
  for (var index = 0; index < arguments.length; index += 1) {
    final argument = arguments[index];
    if (argument == '--source-check-all') {
      all = true;
    } else if (argument == '--source-check') {
      pluginId = _commandValue(arguments, ++index, '--source-check');
    } else if (argument.startsWith('--source-check=')) {
      pluginId = _inlineCommandValue(argument, '--source-check');
    } else if (argument == '--source-check-report') {
      reportPath = _commandValue(arguments, ++index, '--source-check-report');
    } else if (argument.startsWith('--source-check-report=')) {
      reportPath = _inlineCommandValue(argument, '--source-check-report');
    } else {
      throw const SourceVerificationRunException('command_argument_invalid');
    }
  }
  if (all == (pluginId != null)) throw const SourceVerificationRunException('command_selection_invalid');
  final directory = currentDirectory ?? Directory.current.path;
  final selectedPath = reportPath == null
      ? '$directory${Platform.pathSeparator}mgread-source-verification.json'
      : _isAbsolutePath(reportPath)
      ? reportPath
      : '$directory${Platform.pathSeparator}$reportPath';
  return SourceVerificationCommand(pluginId: pluginId, reportPath: File(selectedPath).absolute.path);
}

class SourceVerificationCommandApp extends StatelessWidget {
  const SourceVerificationCommandApp({required this.command, this.terminateProcess = _terminateProcess, super.key});

  final SourceVerificationCommand command;
  final SourceVerificationProcessTerminator terminateProcess;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: _SourceVerificationCommandScreen(command: command, terminateProcess: terminateProcess),
  );
}

class _SourceVerificationCommandScreen extends ConsumerStatefulWidget {
  const _SourceVerificationCommandScreen({required this.command, required this.terminateProcess});

  final SourceVerificationCommand command;
  final SourceVerificationProcessTerminator terminateProcess;

  @override
  ConsumerState<_SourceVerificationCommandScreen> createState() => _SourceVerificationCommandScreenState();
}

class _SourceVerificationCommandScreenState extends ConsumerState<_SourceVerificationCommandScreen> {
  SourceVerificationProgress? _progress;
  String _message = '正在初始化 MgRead 正式运行环境';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final startedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    var exitCode = 2;
    SourceVerificationReport report;
    _writeCliRecord(<String, Object?>{
      'event': 'started',
      'mode': widget.command.all ? 'all' : 'single',
      if (!widget.command.all) 'pluginId': widget.command.pluginId,
    });
    try {
      _writeCliRecord(<String, Object?>{'event': 'startup', 'status': 'running'});
      await ref.read(appStartupControllerProvider).start();
      _writeCliRecord(<String, Object?>{'event': 'startup', 'status': 'passed'});
      report = await ref
          .read(sourceVerificationEngineProvider)
          .run(
            pluginId: widget.command.pluginId,
            onDebug: _writeCliDebug,
            onProgress: (progress) {
              _writeCliRecord(<String, Object?>{
                'event': 'stage',
                'pluginId': progress.pluginId,
                'stage': progress.stage,
                'status': progress.running ? 'running' : 'completed',
              });
              if (!mounted) return;
              setState(() {
                _progress = progress;
                _message = '${progress.displayName} · ${_commandStageLabel(progress.stage)}';
              });
            },
          );
      exitCode = report.isSuccessful
          ? 0
          : report.failedCount == 0 && report.interactionRequiredCount > 0
          ? 3
          : 1;
    } on SourceVerificationRunException catch (error) {
      stopwatch.stop();
      _writeCliError(error.code);
      report = SourceVerificationReport(
        startedAt: startedAt,
        duration: stopwatch.elapsed,
        mode: widget.command.all ? 'all' : 'single',
        sources: const <SourceVerificationSourceResult>[],
        failureCode: error.code,
      );
    } on Object {
      stopwatch.stop();
      _writeCliError('internal');
      report = SourceVerificationReport(
        startedAt: startedAt,
        duration: stopwatch.elapsed,
        mode: widget.command.all ? 'all' : 'single',
        sources: const <SourceVerificationSourceResult>[],
        failureCode: 'internal',
      );
    }
    try {
      await const SourceVerificationReportWriter().write(widget.command.reportPath, report);
    } on Object {
      exitCode = 2;
      _writeCliError('report_write_failed');
    }
    _writeCliResults(report);
    if (mounted) {
      setState(() => _message = report.isSuccessful ? '检测通过，报告已写入' : '检测完成，报告包含异常');
    }
    await stdout.flush();
    await stderr.flush();
    widget.terminateProcess(exitCode);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.section),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(key: Key('source-verification-command-progress')),
              const SizedBox(height: AppSpacing.comfortable),
              Text('MgRead 数据源自检', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: AppSpacing.regular),
              Text(_message, textAlign: TextAlign.center),
              if (_progress != null) ...<Widget>[
                const SizedBox(height: AppSpacing.unit),
                Text(_progress!.pluginId, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

String _commandValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length || arguments[index].isEmpty || arguments[index].startsWith('--')) {
    throw SourceVerificationRunException('${option.substring(2).replaceAll('-', '_')}_missing');
  }
  return arguments[index];
}

String _inlineCommandValue(String argument, String option) {
  final value = argument.substring(option.length + 1);
  if (value.isEmpty) throw SourceVerificationRunException('${option.substring(2).replaceAll('-', '_')}_missing');
  return value;
}

void _writeCliRecord(Map<String, Object?> record) {
  stdout.writeln(jsonEncode(<String, Object?>{'type': 'source_check', ...record}));
}

void _writeCliError(String code) {
  stderr.writeln(jsonEncode(<String, Object?>{'type': 'source_check_log', 'level': 'error', 'code': code}));
}

void _writeCliDebug(SourceVerificationDebugRecord record) {
  _writeCliRecord(<String, Object?>{
    'event': record.event,
    'pluginId': record.pluginId,
    'stage': record.stage,
    if (record.data != null) 'data': record.data,
    if (record.error != null) 'error': record.error.toString(),
    if (record.stackTrace != null) 'stackTrace': record.stackTrace.toString(),
  });
}

void _writeCliResults(SourceVerificationReport report) {
  for (final source in report.sources) {
    for (final stage in source.stages) {
      _writeCliRecord(<String, Object?>{
        'event': 'result',
        'pluginId': source.pluginId,
        'stage': stage.stage,
        'status': stage.status.code,
        'durationMs': stage.duration.inMilliseconds,
        if (stage.code != null) 'code': stage.code,
        if (stage.summary.isNotEmpty) 'summary': stage.summary,
      });
    }
    _writeCliRecord(<String, Object?>{
      'event': 'source_result',
      'pluginId': source.pluginId,
      'status': source.status.code,
      'durationMs': source.duration.inMilliseconds,
      'stages': source.stages.length,
    });
  }
  _writeCliRecord(<String, Object?>{
    'event': 'completed',
    'status': report.isSuccessful ? 'passed' : 'failed',
    'sources': report.sources.length,
    'passed': report.passedCount,
    'failed': report.failedCount,
    'interactionRequired': report.interactionRequiredCount,
    'cancelled': report.cancelledCount,
    if (report.failureCode != null) 'code': report.failureCode,
  });
}

String _commandStageLabel(String stage) {
  if (stage.startsWith('content.')) return '正文或媒体';
  return switch (stage) {
    'discover' => '发现',
    'search' => '搜索',
    'detail' => '详情',
    'chapters' => '目录',
    'content' => '正文或媒体',
    'resource.cover' => '封面资源',
    'resource.content' => '内容资源',
    _ => 'Runtime',
  };
}

Never _terminateProcess(int exitCode) => exit(exitCode);

bool _isAbsolutePath(String path) => RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)').hasMatch(path);
