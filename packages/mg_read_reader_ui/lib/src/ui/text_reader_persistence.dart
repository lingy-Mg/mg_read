part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 生命周期恢复只触发相邻准备 reconcile，不在后台执行预排。
extension _TextReaderPersistence on _TextReaderViewState {
  void _scheduleProgressSave({bool immediate = false}) {
    _saveTimer?.cancel();
    if (immediate) {
      unawaited(_flushProgress());
    } else {
      _saveTimer = Timer(
        _TextReaderViewState._saveDelay,
        () => unawaited(_flushProgress()),
      );
    }
  }

  Future<void> _flushProgress() async {
    _saveTimer?.cancel();
    final ReaderProgress? progress = _progress;
    if (progress == null) return;
    await _queueProgressSave(
      store: widget.stateStore,
      bookId: widget.bookId,
      progress: progress,
    );
  }

  Future<void> _queueProgressSave({
    required TextReaderStateStore store,
    required String bookId,
    required ReaderProgress progress,
  }) {
    final ReaderObserver observer = _observer;
    Future<void> write() async {
      if (identical(_lastProgressStore, store) &&
          _lastProgressBookId == bookId &&
          _lastSavedProgress == progress) {
        return;
      }
      try {
        await store.saveProgress(bookId, progress);
        _lastProgressStore = store;
        _lastProgressBookId = bookId;
        _lastSavedProgress = progress;
      } catch (error) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
    }

    final Map<String, Future<void>> writesForStore = _progressWritesByStore
        .putIfAbsent(store, () => <String, Future<void>>{});
    final Future<void> previous =
        writesForStore[bookId] ?? Future<void>.value();
    final Future<void> next = previous.then(
      (_) => write(),
      onError: (_) => write(),
    );
    writesForStore[bookId] = next;
    unawaited(
      next.then<void>(
        (_) => _removeProgressWrite(store, bookId, next),
        onError: (_) => _removeProgressWrite(store, bookId, next),
      ),
    );
    return next;
  }

  void _removeProgressWrite(
    TextReaderStateStore store,
    String bookId,
    Future<void> completed,
  ) {
    final Map<String, Future<void>>? writesForStore =
        _progressWritesByStore[store];
    if (writesForStore == null ||
        !identical(writesForStore[bookId], completed)) {
      return;
    }
    writesForStore.remove(bookId);
    if (writesForStore.isEmpty) _progressWritesByStore.remove(store);
  }

  Future<void> _queuePreferencesSave({
    required TextReaderStateStore store,
    required TextReaderPreferences preferences,
  }) {
    final ReaderObserver observer = _observer;
    Future<void> write() async {
      if (identical(_lastPreferenceStore, store) &&
          _lastSavedPreferences == preferences) {
        return;
      }
      try {
        await store.savePreferences(preferences);
        _lastPreferenceStore = store;
        _lastSavedPreferences = preferences;
      } catch (error) {
        if (identical(store, widget.stateStore) &&
            preferences == _preferences) {
          _preferencesPreviewDirty = true;
        }
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
    }

    final Future<void> previous =
        _preferenceWritesByStore[store] ?? Future<void>.value();
    final Future<void> next = previous.then(
      (_) => write(),
      onError: (_) => write(),
    );
    _preferenceWritesByStore[store] = next;
    unawaited(
      next.then<void>(
        (_) => _removePreferenceWrite(store, next),
        onError: (_) => _removePreferenceWrite(store, next),
      ),
    );
    return next;
  }

  void _removePreferenceWrite(
    TextReaderStateStore store,
    Future<void> completed,
  ) {
    if (identical(_preferenceWritesByStore[store], completed)) {
      _preferenceWritesByStore.remove(store);
    }
  }

  void _commitPreferencePreview() {
    if (!_preferencesPreviewDirty) return;
    _preferencesPreviewDirty = false;
    unawaited(
      _queuePreferencesSave(
        store: widget.stateStore,
        preferences: _preferences,
      ),
    );
  }

  Future<void> _updatePreferences(TextReaderPreferences value) async {
    await _applyPreferences(value, persist: true);
  }

  Future<void> _applyPreferences(
    TextReaderPreferences value, {
    required bool persist,
  }) async {
    if (_disposed) return;
    final ReaderProgress? anchor = _progress;
    final TextReaderPreferences normalized = value.normalized();
    _cancelAdjacentPreparation();
    final bool commentsChanged =
        normalized.showBookComments != _preferences.showBookComments ||
        normalized.showChapterComments != _preferences.showChapterComments ||
        normalized.showParagraphComments != _preferences.showParagraphComments;
    _lastNonNightTheme = normalized.lastNonNightTheme;
    if (normalized.customFontId == null) {
      _fontLoadGeneration++;
      _runtimeFontFamily = null;
      _runtimeFontDescriptor = null;
    }
    setState(() {
      _preferences = normalized;
    });
    _preferencesPreviewDirty = !persist;
    final Future<void> awakeUpdate = _syncAwake();
    if (normalized.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
    }
    if (persist) {
      await _queuePreferencesSave(
        store: widget.stateStore,
        preferences: normalized,
      );
    }
    await awakeUpdate;
    if (normalized.customFontId != null &&
        normalized.customFontId != _runtimeFontDescriptor?.id) {
      unawaited(_loadPersistedCustomFont());
    }
    if (commentsChanged) unawaited(_refreshCommentSummaries());
  }

  void _handleLifecycle(AppLifecycleState state) {
    final ReaderLifecycleState normalized = switch (state) {
      AppLifecycleState.resumed => ReaderLifecycleState.foreground,
      AppLifecycleState.inactive => ReaderLifecycleState.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => ReaderLifecycleState.background,
      AppLifecycleState.detached => ReaderLifecycleState.detached,
    };
    if (_lifecycleState == normalized) return;
    _lifecycleState = normalized;
    final bool foreground = normalized == ReaderLifecycleState.foreground;
    _foreground = foreground;
    if (!foreground) {
      _chapterPreloadGeneration++;
      _cancelSlowChapterPreload();
      _cancelAdjacentPreparation();
      _stopAutoReading();
      _commitPreferencePreview();
      unawaited(_releaseAwake());
      unawaited(_flushProgress());
    } else {
      unawaited(_syncAwake());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && _chapterIndex >= 0) {
          unawaited(_prefetchNext(_chapterIndex));
        }
      });
    }
    final ReaderObserver observer = _observer;
    final ReaderProgress? progress = _progress;
    unawaited(_notify(() => observer.onLifecycleChanged(normalized, progress)));
  }

  Future<void> _syncAwake() {
    _awakeWrite = _awakeWrite.then(
      (_) => _reconcileAwake(),
      onError: (_) => _reconcileAwake(),
    );
    return _awakeWrite;
  }

  Future<void> _reconcileAwake() async {
    // Controls and settings are temporary system-UI overrides. Keep the
    // persisted preference unchanged so closing either surface restores the
    // reader's immersive intent exactly once.
    final bool immersive =
        !_readerSettingsVisible &&
        !_controlsVisible &&
        _preferences.immersiveMode &&
        _platformCapabilities.immersiveMode;
    final bool shouldAcquire =
        !_disposed &&
        _foreground &&
        _content != null &&
        ((_preferences.keepScreenOn && _platformCapabilities.keepScreenOn) ||
            immersive);
    if (shouldAcquire) {
      try {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn:
              _preferences.keepScreenOn && _platformCapabilities.keepScreenOn,
          immersiveMode: immersive,
        );
        final bool stillDesired =
            !_disposed &&
            _foreground &&
            _content != null &&
            ((_preferences.keepScreenOn &&
                    _platformCapabilities.keepScreenOn) ||
                (!_readerSettingsVisible &&
                    !_controlsVisible &&
                    _preferences.immersiveMode &&
                    _platformCapabilities.immersiveMode));
        if (!stillDesired) {
          await ScreenAwakeCoordinator.instance.release(_awakeHolder);
        }
      } catch (error) {
        try {
          await ScreenAwakeCoordinator.instance.release(_awakeHolder);
        } catch (_) {
          // The original platform failure is the actionable one.
        }
        await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
      }
    } else {
      await _releaseAwakeNow();
    }
  }

  Future<void> _releaseAwake() {
    _awakeWrite = _awakeWrite.then(
      (_) => _releaseAwakeNow(),
      onError: (_) => _releaseAwakeNow(),
    );
    return _awakeWrite;
  }

  Future<void> _releaseAwakeNow() async {
    try {
      await ScreenAwakeCoordinator.instance.release(_awakeHolder);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  void _setControlsVisible(bool value) {
    if (_controlsVisible == value || !mounted) return;
    setState(() => _controlsVisible = value);
    _publishSnapshot();
    unawaited(_syncAwake());
  }

  Future<void> _setReaderSettingsVisible(bool value) async {
    if (_readerSettingsVisible == value || !mounted) return;
    setState(() => _readerSettingsVisible = value);
    if (!_preferences.immersiveMode ||
        !_platformCapabilities.immersiveMode ||
        !_foreground ||
        _content == null) {
      return;
    }
    await _syncAwake();
  }

  bool get _readerInteractionBlocked =>
      _controlsVisible || _readerSettingsVisible;

  void _dismissReaderControlsFromReader() {
    if (!_controlsVisible || !mounted) return;
    _setControlsVisible(false);
  }

  void _dismissReaderSettingsFromReader() {
    if (!_readerSettingsVisible || !mounted) return;
    Navigator.of(context).pop();
  }

  void _publishSnapshot() {
    _controller.updateSnapshot(
      TextReaderSnapshot(
        isReady: (_content != null || _isBookPreview) && _failure == null,
        isLoading: _loading || _changingChapter,
        controlsVisible: _controlsVisible,
        isAutoReading: _autoReadingCoordinator.isRunning,
        book: _book,
        chapter: _currentChapter,
        progress: _progress,
        failure: _failure,
      ),
      owner: _controllerBindingOwner,
    );
  }

  ReaderFailure _asFailure(
    Object error,
    ReaderFailureKind fallbackKind, {
    String? code,
    String? location,
  }) {
    if (error is ReaderFailure) return error;
    return ReaderFailure(
      fallbackKind,
      ReaderStrings.readerProblem,
      code: code ?? 'text_reader_${fallbackKind.name}_failed',
      location: location ?? '文本阅读器',
      cause: error,
    );
  }

  Future<void> _reportFailure(ReaderFailure failure) {
    final ReaderObserver observer = _observer;
    unawaited(_notify(() => observer.onFailure(failure)));
    return Future<void>.value();
  }

  Future<void> _notify(FutureOr<void> Function() callback) {
    return Future<void>.sync(callback).catchError((Object _, StackTrace _) {
      // Host observer failures are isolated and must not change the reading result.
    });
  }

  Future<void> _requestExit() {
    final Future<void>? pending = _exitRequest;
    if (pending != null) return pending;
    final Future<void> request = _performExit();
    _exitRequest = request;
    return request.whenComplete(() {
      if (identical(_exitRequest, request)) _exitRequest = null;
    });
  }

  Future<void> _performExit() async {
    _stopAutoReading();
    _commitPreferencePreview();
    final ReaderObserver observer = _observer;
    final ReaderProgress? progress = _progress;
    // Queue the final semantic state before notifying the host, but do not
    // make route navigation wait for storage I/O.  dispose() retains its own
    // final-save path for exits that happen immediately after this callback.
    unawaited(_flushProgress());
    unawaited(_notify(() => observer.onExitRequested(progress)));
  }
}
