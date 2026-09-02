/// Windows 正式可执行文件的数据源自检命令入口。
///
/// 职责：解析生产参数、在真实 ProviderScope 中调用内置自检引擎、把完整结果写到控制台并返回稳定退出码。
/// 注意：这不是 Flutter 测试入口；CLI 与可见页面复用同一个生产 SourceVerificationEngine。
/// 显式 CLI 测试模式不生成报告文件，完整解码结果和原始异常只写到当前控制台。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

typedef SourceVerificationProcessTerminator = void Function(int exitCode);

final class SourceVerificationCommand {
  const SourceVerificationCommand({required this.pluginId});

  final String? pluginId;

  bool get all => pluginId == null;
}

SourceVerificationCommand? parseSourceVerificationCommand(List<String> arguments) {
  final active = arguments.any(
    (argument) => argument == '--source-check-all' || argument == '--source-check' || argument.startsWith('--source-check='),
  );
  if (!active) return null;
  String? pluginId;
  var all = false;
  for (var index = 0; index < arguments.length; index += 1) {
    final argument = arguments[index];
    if (argument == '--source-check-all') {
      all = true;
    } else if (argument == '--source-check') {
      pluginId = _commandValue(arguments, ++index, '--source-check');
    } else if (argument.startsWith('--source-check=')) {
      pluginId = _inlineCommandValue(argument, '--source-check');
    } else {
      throw const SourceVerificationRunException('command_argument_invalid');
    }
  }
  if (all == (pluginId != null)) throw const SourceVerificationRunException('command_selection_invalid');
  return SourceVerificationCommand(pluginId: pluginId);
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
    _writeCliResults(report);
    if (mounted) {
      setState(() => _message = report.isSuccessful ? '检测通过' : '检测完成，包含异常');
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
  final event = record['event'];
  switch (event) {
    case 'started':
      stdout.writeln('=== MgRead 数据源 CLI 测试开始 ===');
      stdout.writeln('模式: ${record['mode']}');
      if (record['pluginId'] != null) stdout.writeln('插件: ${record['pluginId']}');
    case 'startup':
      stdout.writeln('[启动] ${record['status']}');
    case 'stage':
      stdout.writeln('[阶段] ${record['pluginId']} ${record['stage']} ${record['status']}');
    case 'stage_started':
      stdout.writeln('[${record['pluginId']}] ${record['stage']} 开始');
    case 'stage_response':
      stdout.writeln('[${record['pluginId']}] ${record['stage']} 返回数据:');
      stdout.writeln(record['data']);
    case 'stage_error':
      stdout.writeln('[${record['pluginId']}] ${record['stage']} 失败: ${record['error']}');
      if (record['data'] != null) stdout.writeln('错误详情: ${record['data']}');
      if (record['stackTrace'] != null) stdout.writeln('堆栈:\n${record['stackTrace']}');
    case 'result':
      stdout.writeln(
        '[结果] ${record['pluginId']} ${record['stage']} ${record['status']} '
        'durationMs=${record['durationMs']}${record['code'] == null ? '' : ' code=${record['code']}'}',
      );
      if (record['summary'] != null) stdout.writeln('摘要: ${record['summary']}');
    case 'source_result':
      stdout.writeln(
        '[来源结果] ${record['pluginId']} ${record['status']} '
        'durationMs=${record['durationMs']} stages=${record['stages']}',
      );
    case 'completed':
      stdout.writeln('=== 测试完成: ${record['status']} ===');
      stdout.writeln(
        '来源=${record['sources']} 通过=${record['passed']} 失败=${record['failed']} '
        '需交互=${record['interactionRequired']} 已取消=${record['cancelled']}',
      );
      if (record['code'] != null) stdout.writeln('错误码: ${record['code']}');
    default:
      stdout.writeln('[CLI] $record');
  }
}

void _writeCliError(String code) {
  stderr.writeln('[错误] source-check code=$code');
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
