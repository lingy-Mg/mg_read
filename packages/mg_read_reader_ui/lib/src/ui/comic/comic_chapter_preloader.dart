/// Session-owned ordered preloading. Four asynchronous workers share the image
/// cache's global concurrency limit with visible work. Only current + next
/// chapter are traversed; cancellation stops replenishment and queued work.
library;

import 'dart:async';

import '../../api/comic_models.dart';
import 'comic_image_cache.dart';

class ComicChapterPreloader {
  ComicChapterPreloader(this.cache);

  final ComicImageByteCache cache;
  ComicChapterContent? _current;
  int _generation = 0;

  void start(
    ComicChapterContent chapter, {
    required Future<ComicChapterContent?> Function() nextChapter,
  }) {
    if (identical(_current, chapter)) return;
    cancel();
    _current = chapter;
    final int generation = _generation;
    unawaited(_run(chapter, nextChapter, generation));
  }

  Future<void> _run(
    ComicChapterContent chapter,
    Future<ComicChapterContent?> Function() nextChapter,
    int generation,
  ) async {
    await _loadChapter(chapter, generation);
    if (generation != _generation) return;
    try {
      final next = await nextChapter();
      if (next != null && generation == _generation) {
        await _loadChapter(next, generation);
      }
    } on Object {
      // Chapter boundary UI owns explicit retry and error reporting.
    }
  }

  Future<void> _loadChapter(ComicChapterContent chapter, int generation) async {
    var cursor = 0;
    Future<void> worker() async {
      while (generation == _generation && cursor < chapter.images.length) {
        final image = chapter.images[cursor++];
        try {
          await cache.load(chapter.chapterId, image, visiblePriority: false);
        } on Object {
          // A failed page never prevents later pages from loading. Transport
          // retries belong to the host; the visible tile retains manual retry.
        }
      }
    }

    await Future.wait<void>([
      for (
        var workerIndex = 0;
        workerIndex < cache.maxConcurrentLoads;
        workerIndex++
      )
        worker(),
    ]);
  }

  void cancel() {
    _generation++;
    _current = null;
    cache.cancelPrefetch();
  }
}
