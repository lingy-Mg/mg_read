import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Asynchronous reader command without arguments.
typedef ReaderCommand = Future<void> Function();

/// Asynchronous command that opens a stable chapter identifier.
typedef OpenChapterCommand = Future<void> Function(String chapterId);

/// Optional imperative controller and listenable snapshot for [TextReaderView].
class TextReaderController extends ChangeNotifier {
  /// Creates an unattached controller with an initial loading snapshot.
  TextReaderController();

  TextReaderSnapshot _snapshot = const TextReaderSnapshot.initial();
  OpenChapterCommand? _openChapter;
  ReaderCommand? _nextPage;
  ReaderCommand? _previousPage;
  ReaderCommand? _nextChapter;
  ReaderCommand? _previousChapter;
  ReaderCommand? _showBookPreview;
  ReaderCommand? _toggleControls;
  ReaderCommand? _showControls;
  ReaderCommand? _hideControls;
  ReaderCommand? _refresh;
  ReaderCommand? _startAutoReading;
  ReaderCommand? _stopAutoReading;
  ReaderCommand? _toggleAutoReading;
  Object? _bindingOwner;
  bool _disposed = false;

  /// Latest read-only state published by the attached reader.
  TextReaderSnapshot get snapshot => _snapshot;

  /// Whether this controller is currently attached to a reader state.
  bool get isAttached => !_disposed && _openChapter != null;

  /// Opens [chapterId], or completes safely when the controller is unattached.
  Future<void> openChapter(String chapterId) {
    if (_disposed) return Future<void>.value();
    return _openChapter?.call(chapterId) ?? Future<void>.value();
  }

  /// Advances one page, or completes safely when unavailable.
  Future<void> nextPage() => _invoke(_nextPage);

  /// Moves back one page, or completes safely when unavailable.
  Future<void> previousPage() => _invoke(_previousPage);

  /// Opens the next chapter, or completes safely when unavailable.
  Future<void> nextChapter() => _invoke(_nextChapter);

  /// Opens the previous chapter, or completes safely when unavailable.
  Future<void> previousChapter() => _invoke(_previousChapter);

  /// Opens the metadata preview represented by chapter index `-1`.
  Future<void> showBookPreview() => _invoke(_showBookPreview);

  /// Toggles the reader toolbars, or completes safely when unavailable.
  Future<void> toggleControls() => _invoke(_toggleControls);

  /// Shows the reader toolbars, or completes safely when unavailable.
  Future<void> showControls() => _invoke(_showControls);

  /// Hides the reader toolbars, or completes safely when unavailable.
  Future<void> hideControls() => _invoke(_hideControls);

  /// Reloads the current chapter, or completes safely when unavailable.
  Future<void> refreshCurrentChapter() => _invoke(_refresh);

  /// Starts session-scoped automatic reading when the reader can advance.
  ///
  /// Automatic reading is not persisted and this completes safely when the
  /// controller is unattached or the command is temporarily unavailable.
  Future<void> startAutoReading() => _invoke(_startAutoReading);

  /// Stops session-scoped automatic reading.
  ///
  /// This completes safely when the controller is unattached or automatic
  /// reading is already stopped.
  Future<void> stopAutoReading() => _invoke(_stopAutoReading);

  /// Toggles session-scoped automatic reading when the command is available.
  Future<void> toggleAutoReading() => _invoke(_toggleAutoReading);

  Future<void> _invoke(ReaderCommand? command) {
    if (_disposed || command == null) return Future<void>.value();
    return command();
  }

  @internal
  void bind({
    Object? owner,
    required OpenChapterCommand openChapter,
    required ReaderCommand nextPage,
    required ReaderCommand previousPage,
    required ReaderCommand nextChapter,
    required ReaderCommand previousChapter,
    required ReaderCommand showBookPreview,
    required ReaderCommand toggleControls,
    required ReaderCommand showControls,
    required ReaderCommand hideControls,
    required ReaderCommand refresh,
    ReaderCommand? startAutoReading,
    ReaderCommand? stopAutoReading,
    ReaderCommand? toggleAutoReading,
  }) {
    if (_disposed) return;
    _bindingOwner = owner;
    _openChapter = openChapter;
    _nextPage = nextPage;
    _previousPage = previousPage;
    _nextChapter = nextChapter;
    _previousChapter = previousChapter;
    _showBookPreview = showBookPreview;
    _toggleControls = toggleControls;
    _showControls = showControls;
    _hideControls = hideControls;
    _refresh = refresh;
    _startAutoReading = startAutoReading;
    _stopAutoReading = stopAutoReading;
    _toggleAutoReading = toggleAutoReading;
  }

  @internal
  void updateSnapshot(TextReaderSnapshot value, {Object? owner}) {
    if (_disposed || (owner != null && !identical(_bindingOwner, owner))) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  @internal
  void unbind([Object? owner]) {
    if (owner != null && !identical(_bindingOwner, owner)) return;
    _clearBindings();
  }

  void _clearBindings() {
    _bindingOwner = null;
    _openChapter = null;
    _nextPage = null;
    _previousPage = null;
    _nextChapter = null;
    _previousChapter = null;
    _showBookPreview = null;
    _toggleControls = null;
    _showControls = null;
    _hideControls = null;
    _refresh = null;
    _startAutoReading = null;
    _stopAutoReading = null;
    _toggleAutoReading = null;
  }

  /// Releases listeners and makes every subsequent command a safe no-op.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearBindings();
    super.dispose();
  }
}
