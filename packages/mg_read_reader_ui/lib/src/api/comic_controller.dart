import 'package:flutter/foundation.dart';

import 'comic_models.dart';
import 'controller.dart' show ReaderCommand;

/// Asynchronous command that opens a stable comic chapter identifier.
typedef OpenComicChapterCommand = Future<void> Function(String chapterId);

/// Imperative controller and read-only snapshot for a comic reader.
///
/// Commands safely complete without effect before binding or after disposal.
/// A comic reader is vertically scrolling only, so no page commands exist.
class ComicReaderController extends ChangeNotifier {
  /// Creates an unattached controller with an initial loading snapshot.
  ComicReaderController();

  ComicReaderSnapshot _snapshot = const ComicReaderSnapshot.initial();
  OpenComicChapterCommand? _openChapter;
  ReaderCommand? _nextChapter;
  ReaderCommand? _previousChapter;
  ReaderCommand? _toggleControls;
  ReaderCommand? _showControls;
  ReaderCommand? _hideControls;
  ReaderCommand? _refresh;
  Object? _bindingOwner;
  bool _disposed = false;

  /// Latest state published by the attached comic reader.
  ComicReaderSnapshot get snapshot => _snapshot;

  /// Whether this controller is attached to a live comic reader.
  bool get isAttached => !_disposed && _openChapter != null;

  /// Opens [chapterId], or completes safely when unattached.
  Future<void> openChapter(String chapterId) =>
      _disposed || _openChapter == null
      ? Future<void>.value()
      : _openChapter!(chapterId);

  /// Opens the next chapter when available.
  Future<void> nextChapter() => _invoke(_nextChapter);

  /// Opens the previous chapter when available.
  Future<void> previousChapter() => _invoke(_previousChapter);

  /// Toggles comic reader chrome.
  Future<void> toggleControls() => _invoke(_toggleControls);

  /// Shows comic reader chrome.
  Future<void> showControls() => _invoke(_showControls);

  /// Hides comic reader chrome.
  Future<void> hideControls() => _invoke(_hideControls);

  /// Reloads the current chapter metadata and visible image bytes.
  Future<void> refreshCurrentChapter() => _invoke(_refresh);

  Future<void> _invoke(ReaderCommand? command) =>
      _disposed || command == null ? Future<void>.value() : command();

  /// Binds commands owned by one live comic reader implementation.
  @internal
  void bind({
    Object? owner,
    required OpenComicChapterCommand openChapter,
    required ReaderCommand nextChapter,
    required ReaderCommand previousChapter,
    required ReaderCommand toggleControls,
    required ReaderCommand showControls,
    required ReaderCommand hideControls,
    required ReaderCommand refresh,
  }) {
    if (_disposed) return;
    _bindingOwner = owner;
    _openChapter = openChapter;
    _nextChapter = nextChapter;
    _previousChapter = previousChapter;
    _toggleControls = toggleControls;
    _showControls = showControls;
    _hideControls = hideControls;
    _refresh = refresh;
  }

  /// Publishes a new snapshot from the current binding owner.
  @internal
  void updateSnapshot(ComicReaderSnapshot value, {Object? owner}) {
    if (_disposed || (owner != null && !identical(_bindingOwner, owner))) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  /// Removes commands when [owner] still owns the binding.
  @internal
  void unbind([Object? owner]) {
    if (owner != null && !identical(_bindingOwner, owner)) return;
    _clearBindings();
  }

  void _clearBindings() {
    _bindingOwner = null;
    _openChapter = null;
    _nextChapter = null;
    _previousChapter = null;
    _toggleControls = null;
    _showControls = null;
    _hideControls = null;
    _refresh = null;
  }

  /// Releases listeners and makes subsequent commands safe no-ops.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearBindings();
    super.dispose();
  }
}
