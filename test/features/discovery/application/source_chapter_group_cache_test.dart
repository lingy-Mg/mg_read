/// Cache behavior across repeated clicks, failures, refresh and expiry.
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_chapter_group_cache.dart';

PluginChaptersResult result() => PluginChaptersResult(pluginId: 'source', sourceName: 'Source', items: []);
void main() {
  test('concurrent and repeated selections reuse one request; failures remain retryable', () async {
    final cache = SourceChapterGroupCache();
    final gate = Completer<PluginChaptersResult>();
    var calls = 0;
    Future<PluginChaptersResult> fetch() {
      calls++;
      return gate.future;
    }

    final a = cache.load('source', 'book', 'b', fetch);
    final b = cache.load('source', 'book', 'b', fetch);
    gate.complete(result());
    await Future.wait([a, b]);
    await cache.load('source', 'book', 'b', fetch);
    expect(calls, 1);
    await expectLater(cache.load('source', 'book', 'c', () async => throw StateError('network')), throwsStateError);
    expect(await cache.load('source', 'book', 'c', () async => result()), isA<PluginChaptersResult>());
  });
  test('refresh fences only that content and cannot publish its older result', () async {
    final cache = SourceChapterGroupCache();
    final old = Completer<PluginChaptersResult>();
    final other = Completer<PluginChaptersResult>();
    final a = cache.load('source', 'a', 'line', () => old.future);
    final b = cache.load('source', 'b', 'line', () => other.future);
    cache.invalidate('source', 'a');
    expect(cache.takeRefresh('source', 'a'), isTrue);
    expect(cache.takeRefresh('source', 'a'), isFalse);
    final failure = expectLater(a, throwsStateError);
    old.complete(result());
    other.complete(result());
    await failure;
    await b;
    expect(await cache.load('source', 'a', 'line', () async => result()), isA<PluginChaptersResult>());
  });
  test('expiry and capacity release old metadata instead of growing indefinitely', () async {
    var now = DateTime(2026);
    var calls = 0;
    final cache = SourceChapterGroupCache(now: () => now);
    Future<PluginChaptersResult> fetch() async {
      calls++;
      return result();
    }

    for (var i = 0; i < 5; i++) {
      await cache.load('source', 'book', '$i', fetch);
    }
    await cache.load('source', 'book', '0', fetch);
    expect(calls, 6);
    now = now.add(const Duration(minutes: 6));
    await cache.load('source', 'book', '0', fetch);
    expect(calls, 7);
  });
}
