part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 会话等待上限与失败恢复；不负责网络重试或 IO，宿主仍拥有底层请求。
/// 重试闭包只属于最近一次失败的导航；新导航、重绑或用户关闭提示时释放。
const Duration _chapterRequestTimeout = Duration(seconds: 70);

extension _TextReaderChapterRecovery on _TextReaderViewState {
  Future<T> _awaitChapterRequest<T>(Future<T> request) async {
    final Completer<T> stop = Completer<T>();
    final Future<T> result = Future.any<T>(<Future<T>>[request, stop.future]);
    final Timer timer = Timer(_chapterRequestTimeout, () {
      if (!stop.isCompleted) {
        stop.completeError(
          const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.chapterLoadTimedOut,
            code: 'text_reader_chapter_timeout',
            location: '加载小说章节',
          ),
        );
      }
    });
    void cancel() {
      timer.cancel();
      if (!stop.isCompleted) {
        stop.completeError(StateError(ReaderStrings.staleSession));
      }
    }

    _chapterRequestCancellations.add(cancel);
    try {
      return await result;
    } finally {
      timer.cancel();
      _chapterRequestCancellations.remove(cancel);
    }
  }

  void _cancelChapterRequests() {
    for (final VoidCallback cancel in _chapterRequestCancellations.toList()) {
      cancel();
    }
    _chapterRequestCancellations.clear();
  }

  void _showChapterLoadFailure(Object error, Future<void> Function() retry) {
    _stopAutoReading();
    _failure = _asFailure(error, ReaderFailureKind.data);
    _retryChapterLoad = retry;
    _restoreCurrentHorizontalPage();
    if (mounted) setState(() {});
    _publishSnapshot();
    unawaited(_reportFailure(_failure!));
  }

  Future<void> _retryFailedChapter() async {
    final Future<void> Function()? retry = _retryChapterLoad;
    if (retry == null || _changingChapter) return;
    _retryChapterLoad = null;
    _failure = null;
    await retry();
  }

  void _dismissChapterLoadFailure() {
    _retryChapterLoad = null;
    _failure = null;
    if (mounted) setState(() {});
    _publishSnapshot();
  }
}
