/// Android main-process WebView owner for reverse Core browser requests.
///
/// The Node process never touches Flutter or WebView. This adapter forwards
/// validated requests over a private method channel, polls the host's bounded
/// jobs, and propagates cancellation from the Core wire connection.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'windows_browser_session_host.dart';

final class AndroidNodeBrowserSessionHost implements RuntimeBrowserSessionHost {
  static const _channel = MethodChannel('mgread_plugin_runtime/android_node');
  static const _pollInterval = Duration(milliseconds: 80);
  final Map<String, String> _nativeJobs = <String, String>{};
  final Set<String> _cancelled = <String>{};
  bool _disposed = false;

  @override
  Future<Map<String, Object?>> request({
    required String jobId,
    required int deadlineUnixMs,
    required Map<String, Object?> raw,
  }) async {
    if (_disposed) throw const WindowsBrowserSessionException('unsupported');
    if (DateTime.now().millisecondsSinceEpoch >= deadlineUnixMs) {
      throw const WindowsBrowserSessionException('timeout');
    }
    String? nativeId;
    try {
      nativeId = await _channel.invokeMethod<String>(
        'browserStart',
        <String, Object?>{'request': jsonEncode(raw)},
      );
      if (nativeId == null || nativeId.isEmpty) {
        throw const WindowsBrowserSessionException('plugin_execution_failed');
      }
      _nativeJobs[jobId] = nativeId;
      if (_cancelled.contains(jobId)) {
        throw const WindowsBrowserSessionException('cancelled');
      }
      while (!_disposed) {
        if (_cancelled.contains(jobId)) {
          throw const WindowsBrowserSessionException('cancelled');
        }
        final remaining =
            deadlineUnixMs - DateTime.now().millisecondsSinceEpoch;
        if (remaining <= 0)
          throw const WindowsBrowserSessionException('timeout');
        final encoded = await _channel.invokeMethod<String>(
          'browserPoll',
          <String, Object?>{'id': nativeId},
        );
        if (encoded == null) {
          throw const WindowsBrowserSessionException('plugin_execution_failed');
        }
        final value = jsonDecode(encoded);
        if (value is! Map<Object?, Object?>) {
          throw const WindowsBrowserSessionException('plugin_execution_failed');
        }
        if (value['state'] == 'pending') {
          await Future<void>.delayed(_pollInterval);
          continue;
        }
        if (value['state'] == 'error') {
          final code = value['code'];
          throw WindowsBrowserSessionException(
            code is String ? code : 'plugin_execution_failed',
          );
        }
        final response = value['response'];
        if (value['state'] != 'done' || response is! Map<Object?, Object?>) {
          throw const WindowsBrowserSessionException('plugin_execution_failed');
        }
        return <String, Object?>{
          for (final entry in response.entries)
            if (entry.key is String) entry.key! as String: entry.value,
        };
      }
      throw const WindowsBrowserSessionException('cancelled');
    } on PlatformException catch (error) {
      throw WindowsBrowserSessionException(error.code);
    } finally {
      _nativeJobs.remove(jobId);
      _cancelled.remove(jobId);
      if (nativeId != null) {
        unawaited(
          _channel
              .invokeMethod<void>('browserCancel', <String, Object?>{
                'id': nativeId,
              })
              .catchError((Object _) {}),
        );
      }
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelled.add(jobId);
    final nativeId = _nativeJobs[jobId];
    if (nativeId != null) {
      await _channel.invokeMethod<void>('browserCancel', <String, Object?>{
        'id': nativeId,
      });
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final id in _nativeJobs.keys.toList()) {
      await cancel(id);
    }
  }
}
