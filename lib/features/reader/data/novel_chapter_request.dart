/// 小说宿主正文请求的超时、瞬时失败退避与 Runtime 取消边界。
///
/// 每次最多请求三次；超时先取消该次 Runtime 调用，迟到结果不进入正文缓存。
/// 调用方仍拥有持久化与请求去重，失败后必须释放共享 Future 以允许手动重试。
library;

import 'dart:async';
import 'dart:io';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

Future<T> requestNovelChapter<T>(Future<T> Function() request, {SourceContentGateway? gateway}) async {
  for (var attempt = 0; ; attempt++) {
    final cancellation = PluginInvocationCancellation();
    try {
      final pending = gateway is CancellableSourceContentGateway
          ? (gateway as CancellableSourceContentGateway).runCancellable(cancellation, request)
          : Future<T>.sync(request);
      return await pending.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          cancellation.cancel();
          throw TimeoutException('小说章节请求超时，请重试。');
        },
      );
    } on Object catch (error) {
      if (attempt >= 2 || !_isTransient(error)) rethrow;
      await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 500 : 1000));
    }
  }
}

bool _isTransient(Object error) => switch (error) {
  TimeoutException() || SocketException() => true,
  AppError(:final code, :final retryable) =>
    code == AppErrorCode.timeout ||
        code == AppErrorCode.transportDisconnected ||
        (retryable && code != AppErrorCode.sourceAccessBlocked && code != AppErrorCode.cancelled),
  PluginRuntimeException(:final code) => const <String>{
    'timeout',
    'transport_disconnected',
    'runtime_not_ready',
    'rate_limited',
    'overloaded',
  }.contains(code),
  _ => false,
};
