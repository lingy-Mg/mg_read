part of 'comic_reader_view.dart';

/// 会话拥有内存探测、预算更新与前台计时器；不阻塞正文或重建章节。
/// 查询超时/旧桥缺失时沿用当前预算，过期结果不得撤销内存压力后的收缩。
extension _ComicReaderMemory on _ComicReaderViewState {
  void _applyImageMemoryPolicy(ComicImageMemoryPolicy policy) {
    _imageMemoryPolicy = policy;
    _decodeBudget.updateLimits(
      maximumPixels: policy.maximumPixels,
      maximumImagePixels: policy.maximumImagePixels,
    );
    _imageCache.updateByteLimit(policy.encodedCacheBytes);
  }

  Future<void> _refreshMemoryBudget() async {
    if (_disposed || !_foreground) return;
    _stopMemoryBudgetRefresh();
    final int generation = _memoryBudgetGeneration;
    try {
      final ReaderDeviceMemoryInfo? memory = await _queryDeviceMemory();
      if (_disposed || !_foreground || generation != _memoryBudgetGeneration) {
        return;
      }
      if (memory != null) {
        _memoryInfoSupported = true;
        _applyImageMemoryPolicy(ComicImageMemoryPolicy.forDevice(memory));
      }
    } catch (_) {
      // This optional probe must not turn an otherwise readable image into
      // a platform failure or increase the budget after a failed recovery.
    } finally {
      if (!_disposed && _foreground && generation == _memoryBudgetGeneration) {
        _scheduleMemoryBudgetRefresh();
      }
    }
  }

  Future<ReaderDeviceMemoryInfo?> _queryDeviceMemory() async {
    final stop = Completer<ReaderDeviceMemoryInfo?>();
    _memoryProbeStop = stop;
    _memoryProbeTimer = Timer(const Duration(seconds: 2), () {
      if (!stop.isCompleted) stop.complete(null);
    });
    try {
      return await Future.any<ReaderDeviceMemoryInfo?>([
        Future<ReaderDeviceMemoryInfo?>.sync(
          ReaderPlatform.instance.deviceMemoryInfo,
        ),
        stop.future,
      ]);
    } finally {
      if (identical(_memoryProbeStop, stop)) {
        _memoryProbeTimer?.cancel();
        _memoryProbeTimer = null;
        _memoryProbeStop = null;
      }
    }
  }

  void _scheduleMemoryBudgetRefresh({bool force = false}) {
    _memoryBudgetTimer?.cancel();
    if (_disposed || !_foreground || (!_memoryInfoSupported && !force)) return;
    _memoryBudgetTimer = Timer(
      const Duration(seconds: 30),
      () => unawaited(_refreshMemoryBudget()),
    );
  }

  void _stopMemoryBudgetRefresh() {
    _memoryBudgetGeneration++;
    _memoryBudgetTimer?.cancel();
    _memoryBudgetTimer = null;
    _memoryProbeTimer?.cancel();
    _memoryProbeTimer = null;
    final stop = _memoryProbeStop;
    _memoryProbeStop = null;
    if (stop != null && !stop.isCompleted) stop.complete(null);
  }
}
