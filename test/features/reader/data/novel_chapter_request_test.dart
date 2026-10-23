import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/novel_chapter_request.dart';

void main() {
  for (final error in <Object>[
    TimeoutException('timeout'),
    const SocketException('offline'),
    AppError.fromCode(AppErrorCode.timeout),
    AppError.fromCode(AppErrorCode.transportDisconnected),
    AppError.fromCode(AppErrorCode.overloaded),
    const PluginRuntimeException('timeout', 'timeout'),
  ]) {
    testWidgets('retries transient ${error.runtimeType}: $error with bounded backoff', (tester) async {
      var attempts = 0;
      final result = requestNovelChapter(() async {
        if (++attempts < 3) throw error;
        return '正文';
      });
      await tester.pump();
      expect(attempts, 1);
      await tester.pump(const Duration(milliseconds: 499));
      expect(attempts, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, 2);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(await result, '正文');
      expect(attempts, 3);
    });
  }

  for (final error in <Object>[
    StateError('invalid content'),
    AppError.fromCode(AppErrorCode.notFound),
    AppError.fromCode(AppErrorCode.cancelled),
    AppError.fromCode(AppErrorCode.interactionRequired),
    AppError.fromCode(AppErrorCode.sourceAccessBlocked),
    const PluginRuntimeException('cancelled', 'cancelled'),
  ]) {
    testWidgets('does not automatically retry permanent $error', (tester) async {
      var attempts = 0;
      final result = requestNovelChapter<String>(() async {
        attempts++;
        throw error;
      });
      await expectLater(result, throwsA(same(error)));
      expect(attempts, 1);
    });
  }

  testWidgets('hung requests cancel each Runtime attempt and stop after three attempts', (tester) async {
    final gateway = _CancellableGateway();
    final pending = <Completer<String>>[];
    final result = requestNovelChapter(() {
      final request = Completer<String>();
      pending.add(request);
      return request.future;
    }, gateway: gateway);
    final assertion = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 20));
    expect(gateway.cancellations.single.isCancelled, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(pending, hasLength(2));
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(pending, hasLength(3));
    await tester.pump(const Duration(seconds: 20));
    await assertion;
    expect(gateway.cancellations.every((value) => value.isCancelled), isTrue);
    for (final request in pending) {
      request.complete('迟到正文');
    }
    await tester.pump();
    expect(pending, hasLength(3));
    expect(tester.takeException(), isNull);
  });
}

class _CancellableGateway implements SourceContentGateway, CancellableSourceContentGateway {
  final cancellations = <PluginInvocationCancellation>[];
  @override
  Future<T> runCancellable<T>(PluginInvocationCancellation cancellation, Future<T> Function() request) {
    cancellations.add(cancellation);
    return Future<T>.sync(request);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
