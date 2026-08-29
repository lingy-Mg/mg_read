/// 阅读器章节缓存入口。
///
/// 职责：
/// - 在正文顶栏更多菜单中通过滑动条收集章节数，并横向组合并发数与请求延迟。
/// - 只将经过边界校验的意图交给宿主 capability。
///
/// 注意：
/// - 不访问网络、文件或持久化，也不拥有全局任务进度与取消状态。
part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

enum _ReaderOverflowAction { cacheChapters }

extension _TextReaderCacheDialog on _TextReaderViewState {
  Widget _buildReaderOverflowMenu() {
    return ReaderAccessibleTooltip(
      key: const ValueKey<String>('reader-top-overflow'),
      label: ReaderStrings.more,
      expanded: _readerOverflowMenuExpanded,
      onTap: _showReaderOverflowMenu,
      child: PopupMenuButton<_ReaderOverflowAction>(
        key: _readerOverflowMenuKey,
        // The outer stable tooltip owns hover and accessibility. Keeping this
        // empty prevents PopupMenuButton from adding a second OverlayPortal.
        tooltip: '',
        icon: const ExcludeSemantics(child: Icon(Icons.more_vert_rounded)),
        onOpened: () => _setReaderOverflowMenuExpanded(true),
        onCanceled: () => _setReaderOverflowMenuExpanded(false),
        onSelected: (_ReaderOverflowAction action) {
          _setReaderOverflowMenuExpanded(false);
          switch (action) {
            case _ReaderOverflowAction.cacheChapters:
              unawaited(_showCacheChaptersDialog());
          }
        },
        itemBuilder: (BuildContext context) =>
            const <PopupMenuEntry<_ReaderOverflowAction>>[
              PopupMenuItem<_ReaderOverflowAction>(
                value: _ReaderOverflowAction.cacheChapters,
                child: Row(
                  children: <Widget>[
                    Icon(Icons.download_for_offline_outlined, size: 20),
                    SizedBox(width: 12),
                    Text(ReaderStrings.cacheChapters),
                  ],
                ),
              ),
            ],
      ),
    );
  }

  void _showReaderOverflowMenu() {
    _readerOverflowMenuKey.currentState?.showButtonMenu();
  }

  void _setReaderOverflowMenuExpanded(bool expanded) {
    if (!mounted || _readerOverflowMenuExpanded == expanded) return;
    setState(() => _readerOverflowMenuExpanded = expanded);
  }

  Future<void> _showCacheChaptersDialog() async {
    final ReaderChapterCacheCapability? capability =
        widget.extensions.chapterCacheCapability;
    if (capability == null) return;
    final int reportedTotal = _catalogTotal > 0
        ? _catalogTotal
        : (_book?.chapterCount ?? _catalog.length);
    final int total = reportedTotal < 0 ? 0 : reportedTotal;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    int chapterCount = 0;
    int concurrency = 1;
    int delaySeconds = 3;

    final ReaderChapterCacheRequest?
    request = await showDialog<ReaderChapterCacheRequest>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext dialogContext, StateSetter setDialogState) =>
            AlertDialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 24,
              ),
              constraints: const BoxConstraints(maxWidth: 560),
              title: const Text(ReaderStrings.cacheChapters),
              contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              content: SizedBox(
                width: double.maxFinite,
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${ReaderStrings.chapterCountRange}：${ReaderStrings.chapterCountRangeLabel(total)}',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ReaderStrings.cacheChapterRangeHint,
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: <Widget>[
                            const Text(ReaderStrings.cacheChapterCount),
                            const Spacer(),
                            Text(
                              '$chapterCount / $total',
                              key: const ValueKey<String>(
                                'reader-cache-chapter-value',
                              ),
                              style: Theme.of(
                                dialogContext,
                              ).textTheme.titleSmall,
                            ),
                          ],
                        ),
                        Slider(
                          key: const ValueKey<String>(
                            'reader-cache-chapter-slider',
                          ),
                          value: chapterCount.toDouble(),
                          min: 0,
                          max: total == 0 ? 1 : total.toDouble(),
                          divisions: total == 0 ? null : total,
                          label: '$chapterCount',
                          semanticFormatterCallback: (double value) =>
                              '缓存 ${value.round()} 章，共 $total 章',
                          onChanged: total == 0
                              ? null
                              : (double value) {
                                  setDialogState(() {
                                    chapterCount = value.round().clamp(
                                      0,
                                      total,
                                    );
                                  });
                                },
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[Text('0'), Text('$total')],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: TextFormField(
                                key: const ValueKey<String>(
                                  'reader-cache-concurrency',
                                ),
                                initialValue: '1',
                                keyboardType: TextInputType.number,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: const InputDecoration(
                                  labelText: ReaderStrings.cacheConcurrency,
                                  helperText: '1–8',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (String? value) {
                                  final int? parsed = int.tryParse(value ?? '');
                                  return parsed == null ||
                                          parsed < 1 ||
                                          parsed > 8
                                      ? '1–8'
                                      : null;
                                },
                                onChanged: (String value) {
                                  concurrency = int.tryParse(value) ?? 0;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                key: const ValueKey<String>(
                                  'reader-cache-delay',
                                ),
                                initialValue: '3',
                                keyboardType: TextInputType.number,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: const InputDecoration(
                                  labelText: ReaderStrings.cacheDelay,
                                  suffixText: ReaderStrings.cacheDelaySeconds,
                                  helperText: '0–60',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (String? value) {
                                  final int? parsed = int.tryParse(value ?? '');
                                  return parsed == null ||
                                          parsed < 0 ||
                                          parsed > 60
                                      ? '0–60'
                                      : null;
                                },
                                onChanged: (String value) {
                                  delaySeconds = int.tryParse(value) ?? -1;
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text(ReaderStrings.close),
                ),
                FilledButton(
                  key: const ValueKey<String>('reader-cache-start'),
                  onPressed: () {
                    if (formKey.currentState?.validate() != true) return;
                    Navigator.of(dialogContext).pop(
                      ReaderChapterCacheRequest(
                        chapterCount: chapterCount,
                        concurrency: concurrency,
                        delay: Duration(seconds: delaySeconds),
                      ),
                    );
                  },
                  child: const Text(ReaderStrings.startCaching),
                ),
              ],
            ),
      ),
    );
    if (request == null || !_isRouteSessionCurrent(session, bookId)) return;
    try {
      await capability.startCaching(bookId, request);
    } catch (error) {
      if (_isRouteSessionCurrent(session, bookId)) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      }
    }
  }
}
