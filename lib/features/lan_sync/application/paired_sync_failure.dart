/// 已配对同步的分阶段失败投影与 owner-span 诊断。
///
/// UI 只展示有界技术原因；调试控制台和显式诊断记录保留完整异常文本与堆栈。
/// 诊断失败必须与同步业务结果隔离。
library;

import 'dart:async';
import 'dart:io';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

final class PairedSyncFailure {
  const PairedSyncFailure({
    required this.code,
    required this.stage,
    required this.errorText,
    required this.stackTrace,
    this.remote = false,
  });

  factory PairedSyncFailure.fromException({required String stage, required Object error, required StackTrace stackTrace, String? code}) {
    var cause = error;
    var causeStackTrace = stackTrace;
    if (error is PairedSyncPartialException) {
      cause = error.cause;
      causeStackTrace = error.causeStackTrace;
      stage = error.stage;
      code ??= 'device_sync_partial';
    }
    stage = _failureStage(stage, cause);
    return PairedSyncFailure(
      code: code ?? _failureCode(stage, cause),
      stage: stage,
      errorText: _technicalErrorText(cause),
      stackTrace: causeStackTrace.toString(),
    );
  }

  factory PairedSyncFailure.remote({
    required String code,
    required String stage,
    required String errorText,
    required StackTrace receiptStackTrace,
  }) => PairedSyncFailure(code: code, stage: stage, errorText: errorText, stackTrace: receiptStackTrace.toString(), remote: true);

  final String code;
  final String stage;
  final String errorText;
  final String stackTrace;
  final bool remote;

  String get uiDetails {
    final technical = _singleLine(errorText, maximumLength: 360);
    return '阶段：${pairedSyncStageLabel(stage)}\n错误码：$code\n技术原因：$technical';
  }
}

final class PairedSyncDiagnosticSession {
  PairedSyncDiagnosticSession._({
    required this._diagnostics,
    required this._span,
    required this.role,
    required this.operation,
    required this.automatic,
    required this.peerPlatform,
  }) : _stopwatch = Stopwatch()..start();

  factory PairedSyncDiagnosticSession.start(
    DiagnosticsManager diagnostics, {
    required String role,
    required PairedSyncOperation operation,
    required bool automatic,
    required PairedDevicePlatform peerPlatform,
  }) {
    DiagnosticSpanHandle? span;
    try {
      span = diagnostics.startSpan(
        AppDiagnosticEvents.lanSyncSession,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'role': DiagnosticValue.string(role),
          'stage': DiagnosticValue.string('start'),
          'operation': DiagnosticValue.string(operation.name),
          'automatic': DiagnosticValue.boolean(automatic),
          'peerPlatform': DiagnosticValue.string(peerPlatform.name),
        }),
      );
    } on Object {
      span = null;
    }
    return PairedSyncDiagnosticSession._(
      diagnostics: diagnostics,
      span: span,
      role: role,
      operation: operation,
      automatic: automatic,
      peerPlatform: peerPlatform,
    );
  }

  final DiagnosticsManager _diagnostics;
  final String role;
  final PairedSyncOperation operation;
  final bool automatic;
  final PairedDevicePlatform peerPlatform;
  final Stopwatch _stopwatch;
  DiagnosticSpanHandle? _span;
  String _stage = 'start';

  String get stageName => _stage;

  void stage(String value) {
    _stage = value;
    final span = _span;
    if (span == null) return;
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.lanSyncStage,
        traceContext: span.traceContext,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'role': DiagnosticValue.string(role),
          'stage': DiagnosticValue.string(value),
          'bytes': DiagnosticValue.int64(0),
          'elapsedMicros': DiagnosticValue.int64(_stopwatch.elapsedMicroseconds),
        }),
      );
    } on Object {
      // 诊断不得改变同步阶段。
    }
  }

  void complete(PairedSyncRunSummary summary) {
    final span = _takeSpan();
    if (span == null) return;
    try {
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          ..._terminalAttributes(resultState: 'success'),
          'pluginCount': DiagnosticValue.int64(summary.receivedPlugins + summary.sentPlugins),
          'itemCount': DiagnosticValue.int64(summary.receivedBooks + summary.sentBooks),
        }),
      );
    } on Object {
      // 诊断不得改变同步终态。
    }
  }

  void fail(PairedSyncFailure failure, {bool partial = false}) {
    _stage = failure.stage;
    final span = _takeSpan();
    if (span == null) return;
    final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
      ..._terminalAttributes(resultState: partial ? 'partial' : 'failure'),
      'errorCode': DiagnosticValue.string(failure.code),
      'errorLocation': DiagnosticValue.string(failure.stage),
      'errorText': DiagnosticValue.string(failure.errorText),
      'stackTrace': DiagnosticValue.string(failure.stackTrace),
    });
    try {
      if (failure.code.contains('timeout')) {
        span.timeout(attributes: attributes);
      } else {
        span.fail(attributes: attributes);
      }
    } on Object {
      // 诊断不得改变同步终态。
    }
  }

  Map<String, DiagnosticValue> _terminalAttributes({required String resultState}) => <String, DiagnosticValue>{
    'role': DiagnosticValue.string(role),
    'stage': DiagnosticValue.string(_stage),
    'operation': DiagnosticValue.string(operation.name),
    'automatic': DiagnosticValue.boolean(automatic),
    'peerPlatform': DiagnosticValue.string(peerPlatform.name),
    'resultState': DiagnosticValue.string(resultState),
    'bytes': DiagnosticValue.int64(0),
  };

  DiagnosticSpanHandle? _takeSpan() {
    _stopwatch.stop();
    final span = _span;
    _span = null;
    return span;
  }
}

String pairedSyncFailureMessage(PairedDevice device, PairedSyncFailure failure, {required bool automatic}) {
  final retry = automatic ? '，稍后会自动重试' : '';
  if (failure.remote) {
    return '${device.label} 回连后在“${pairedSyncStageLabel(failure.stage)}”阶段失败$retry';
  }
  return switch (failure.code) {
    'lan_sync_peer_offline' => '${device.label} 当前未被局域网发现，请确认两端都已打开',
    'lan_sync_reverse_connect_timeout' => '${device.label} 已收到请求但未能回连；请确认电脑端已更新并保持运行$retry',
    'paired_secret_missing' => '与 ${device.label} 的配对密钥已丢失，请重新配对',
    'lan_sync_connect_failed' when device.platform == PairedDevicePlatform.windows =>
      '无法连接 ${device.label}；请确认 Windows 防火墙允许 MgRead 使用专用网络$retry',
    'lan_sync_connect_failed' => '无法连接 ${device.label}，请确认两台设备仍在同一局域网$retry',
    'lan_sync_peer_busy' => '${device.label} 正在执行另一次同步，请稍后重试',
    'lan_sync_peer_not_paired' || 'lan_sync_handshake_invalid' => '与 ${device.label} 的配对信息已不一致，请解除后重新配对',
    'device_sync_partial' => '与 ${device.label} 已同步部分内容；在 ${pairedSyncStageLabel(failure.stage)} 阶段中断$retry',
    _ => '与 ${device.label} 同步失败：${pairedSyncStageLabel(failure.stage)}$retry',
  };
}

String pairedSyncStageLabel(String stage) => switch (stage) {
  'identity' => '读取配对身份',
  'host_start' => '启动局域网同步服务',
  'policy' => '检查同步方向',
  'discovery' => '发现在线设备',
  'wake_send' => '发送反向连接请求',
  'wake_wait' => '等待电脑回连',
  'connect' => '建立局域网连接',
  'authentication' => '配对认证',
  'request' => '协商同步方向',
  'local_manifest' => '生成本机清单',
  'manifest_exchange' => '交换同步清单',
  'import_plan' => '计算接收计划',
  'selection_exchange' => '确认传输项目',
  'receive_payload' => '接收并导入数据',
  'send_payload' => '打包并发送数据',
  'complete' => '确认同步结果',
  'result_persist' => '保存同步状态',
  'library_refresh' => '刷新首页书架',
  _ => stage,
};

String _failureCode(String stage, Object error) {
  if (error is LanSyncTransportException) return error.code;
  if (error is LanSyncGatewayException) return 'lan_sync_${stage}_${error.code}';
  if (error is TimeoutException) return 'lan_sync_${stage}_timeout';
  if (error is SocketException) return 'lan_sync_${stage}_socket_error';
  if (error is StateError && error.message == 'paired_secret_missing') return 'paired_secret_missing';
  return 'device_sync_${stage}_failed';
}

String _failureStage(String stage, Object error) {
  if (error is! LanSyncTransportException) return stage;
  return switch (error.code) {
    'lan_sync_handshake_invalid' || 'lan_sync_peer_not_paired' || 'lan_sync_protocol_incompatible' => 'authentication',
    'lan_sync_manifest_invalid' || 'lan_sync_policy_invalid' => 'manifest_exchange',
    'lan_sync_selection_invalid' => 'selection_exchange',
    'lan_sync_plugin_size_mismatch' ||
    'lan_sync_plugin_frame_invalid' ||
    'lan_sync_transfer_incomplete' ||
    'lan_sync_disconnected' => stage == 'send_payload' ? 'send_payload' : 'receive_payload',
    _ => stage,
  };
}

String _technicalErrorText(Object error) {
  if (error is LanSyncGatewayException) return 'LanSyncGatewayException(${error.code})';
  return '${error.runtimeType}: $error';
}

String _singleLine(String value, {required int maximumLength}) {
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= maximumLength) return compact;
  return '${compact.substring(0, maximumLength - 1)}…';
}
