/// App-lifetime coordinator for local TXT/EPUB import and library management.
/// It retains selected input handles only while work is active; durable jobs and
/// recovery belong to ContentLibrary. No source path is written to the journal.
/// Changed document snapshots notify the host's shelf/statistics projections.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';

import '../data/local_import_ingress.dart';

final localContentLibraryProvider = Provider<Future<ContentLibrary> Function()>(
  (ref) =>
      () => Future<ContentLibrary>.error(StateError('Content Library is not available')),
);

final localImportControllerProvider = ChangeNotifierProvider<LocalImportController>((ref) {
  return LocalImportController(
    ref.read(localContentLibraryProvider),
    onLibraryChanged: () {
      ref.invalidate(libraryPageControllerProvider);
      ref.invalidate(privateLibraryPageControllerProvider);
      ref.invalidate(profileReadingStatsProvider);
    },
  );
});

class LocalImportController extends ChangeNotifier {
  LocalImportController(this._getLibrary, {VoidCallback? onLibraryChanged}) : _onLibraryChanged = onLibraryChanged {
    _ingressSubscription = LocalImportIngress.instance.pendingInputs.listen((inputs) => acceptInputs(inputs, openAsRequest: true));
    for (final inputs in LocalImportIngress.instance.takeBufferedInputs()) {
      acceptInputs(inputs, openAsRequest: true);
    }
    unawaited(LocalImportIngress.instance.install());
    unawaited(reload());
  }

  final Future<ContentLibrary> Function() _getLibrary;
  final VoidCallback? _onLibraryChanged;
  final List<LocalImportInput> _selected = <LocalImportInput>[];
  final Map<String, LocalImportInput> _retryInputs = <String, LocalImportInput>{};
  final Map<String, List<String>> _previews = <String, List<String>>{};
  final Map<String, List<int>?> _covers = <String, List<int>?>{};
  final Map<String, String> _lastErrors = <String, String>{};
  final Map<String, LocalDocumentParseOptions> _options = <String, LocalDocumentParseOptions>{};
  final Map<String, ({String title, String? author})> _metadata = <String, ({String title, String? author})>{};
  final List<List<LocalImportInput>> _openRequests = <List<LocalImportInput>>[];
  StreamSubscription<LocalImportSnapshot>? _eventsSubscription;
  StreamSubscription<List<LocalImportInput>>? _ingressSubscription;
  List<LocalImportSnapshot> _jobs = <LocalImportSnapshot>[];
  List<LibraryItem> _documents = <LibraryItem>[];
  bool _loading = false;
  int _usageBytes = 0;
  bool _disposed = false;
  int _batchCurrent = 0;
  int _batchTotal = 0;
  bool _batchCancelled = false;
  String? _activeBatchJobId;
  List<String> _batchPlanIds = <String>[];
  final Set<String> _batchProcessedIds = <String>{};
  final Map<String, Future<void>> _batchCancelFutures = <String, Future<void>>{};

  List<LocalImportInput> get selected => List.unmodifiable(_selected);
  List<LocalImportSnapshot> get jobs => List.unmodifiable(_jobs);
  List<LibraryItem> get documents => List.unmodifiable(_documents);
  Map<String, List<String>> get previews => Map.unmodifiable(_previews);
  Map<String, List<int>?> get covers => Map.unmodifiable(_covers);
  Map<String, String> get errors => Map.unmodifiable(_lastErrors);
  Map<String, LocalDocumentParseOptions> get options => Map.unmodifiable(_options);
  int get readyCount => _jobs.where((job) => job.status == LocalImportStatus.awaitingConfirmation).length;
  String errorLabel(LocalImportSnapshot job) => _friendlyJobError(job);
  bool get loading => _loading;
  int get usageBytes => _usageBytes;
  int get batchCurrent => _batchCurrent;
  int get batchTotal => _batchTotal;
  int get pendingOpenCount => _openRequests.length;

  bool takePendingOpenRequest() {
    if (_openRequests.isEmpty) return false;
    _openRequests.removeAt(0);
    return true;
  }

  void queuePaths(List<String> paths) {
    final inputs = <LocalImportInput>[];
    for (final path in paths) {
      if (path.trim().isEmpty) continue;
      final file = File(path);
      inputs.add(LocalImportInput(fileName: path.split(RegExp(r'[/\\]')).last, openRead: file.openRead));
    }
    if (inputs.isNotEmpty) acceptInputs(inputs, openAsRequest: true);
  }

  void acceptInputs(List<LocalImportInput> inputs, {bool openAsRequest = false}) {
    final valid = inputs.where((input) => _supported(input.fileName)).toList();
    if (openAsRequest && valid.isNotEmpty) _openRequests.add(valid);
    for (final input in inputs) {
      if (!_supported(input.fileName)) {
        _lastErrors[input.fileName] = '仅支持 TXT 和 EPUB 文件';
        unawaited(LocalImportIngress.instance.releaseInput(input));
        continue;
      }
      if (_selected.length >= 100) {
        _lastErrors[input.fileName] = '单次最多选择 100 个文件';
        unawaited(LocalImportIngress.instance.releaseInput(input));
        continue;
      }
      _selected.add(input);
    }
    _notify();
  }

  void removeSelected(LocalImportInput input) {
    _selected.remove(input);
    unawaited(LocalImportIngress.instance.releaseInput(input));
    _notify();
  }

  Future<void> pickFiles() async {
    try {
      acceptInputs(await LocalImportIngress.instance.pickDocuments());
    } on Object catch (error) {
      _lastErrors['picker'] = _friendlyError(error);
      _notify();
    }
  }

  Future<void> reload() async {
    _loading = true;
    _notify();
    try {
      final library = await _getLibrary();
      await _eventsSubscription?.cancel();
      _eventsSubscription = library.localImportEvents.listen((snapshot) {
        if (_batchTotal > 0 && _batchPlanIds.contains(snapshot.id)) {
          if (const <LocalImportStatus>{
            LocalImportStatus.acquiring,
            LocalImportStatus.inspecting,
            LocalImportStatus.parsing,
            LocalImportStatus.validating,
            LocalImportStatus.committing,
          }.contains(snapshot.status)) {
            _activeBatchJobId = snapshot.id;
          } else if (_activeBatchJobId == snapshot.id &&
              (snapshot.isTerminal ||
                  snapshot.status == LocalImportStatus.awaitingConfirmation ||
                  snapshot.status == LocalImportStatus.needsAction)) {
            _activeBatchJobId = null;
          }
        }
        _upsertJob(snapshot);
        if (snapshot.status == LocalImportStatus.awaitingConfirmation) unawaited(_loadPreview(library, snapshot.id));
        if (snapshot.isTerminal) unawaited(_refreshDocuments(library));
      });
      _jobs = await library.localImportJobs();
      _replaceDocuments(await library.listLocalDocuments(includeRetained: true));
      _usageBytes = await library.localDocumentUsageBytes();
    } on Object catch (error) {
      _lastErrors['library'] = _friendlyError(error);
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> importSelected({LocalDocumentParseOptions options = const LocalDocumentParseOptions()}) async {
    if (_selected.isEmpty || _batchTotal > 0) return;
    final batch = List<LocalImportInput>.of(_selected);
    _selected.clear();
    _batchCurrent = 0;
    _batchTotal = batch.length;
    _batchCancelled = false;
    _activeBatchJobId = null;
    _batchPlanIds = <String>[];
    _batchProcessedIds.clear();
    _batchCancelFutures.clear();
    _notify();
    late final ContentLibrary library;
    try {
      library = await _getLibrary();
    } on Object catch (error) {
      _lastErrors['library'] = _friendlyError(error);
      _selected.addAll(batch);
      _batchTotal = 0;
      _notify();
      return;
    }
    final plans = <({LocalImportSnapshot snapshot, LocalImportInput input, int index})>[];
    for (var index = 0; index < batch.length; index++) {
      final input = batch[index];
      try {
        final job = await library.queueLocalImport(input, options: options);
        plans.add((snapshot: job, input: input, index: index));
        _batchPlanIds.add(job.id);
        _upsertJob(job);
      } on Object catch (error) {
        _lastErrors[input.fileName] = _friendlyError(error);
        _selected.add(input);
      }
      _notify();
    }
    for (var planIndex = 0; planIndex < plans.length; planIndex++) {
      if (_batchCancelled) {
        final remaining = plans.skip(planIndex).where((plan) => !_batchProcessedIds.contains(plan.snapshot.id)).toList();
        for (final plan in remaining) {
          await _cancelQueuedJob(library, plan.snapshot.id);
        }
        _selected.addAll(remaining.map((plan) => plan.input));
        break;
      }
      final plan = plans[planIndex];
      final input = plan.input;
      _batchCurrent++;
      _activeBatchJobId = plan.snapshot.id;
      try {
        final job = await library.prepareLocalImport(input, options: options, queuedJobId: plan.snapshot.id);
        _activeBatchJobId = null;
        _batchProcessedIds.add(job.id);
        _retryInputs[job.id] = input;
        _options[job.id] = options;
        _upsertJob(job);
        if (job.status == LocalImportStatus.awaitingConfirmation) {
          await _loadPreview(library, job.id);
          _retryInputs.remove(job.id);
          await LocalImportIngress.instance.releaseInput(input);
        } else if (job.status == LocalImportStatus.failed) {
          _lastErrors[job.id] = _friendlyJobError(job);
        } else if (job.status == LocalImportStatus.cancelled) {
          _retryInputs.remove(job.id);
          await LocalImportIngress.instance.releaseInput(input);
        }
      } on Object catch (error) {
        _activeBatchJobId = null;
        _batchProcessedIds.add(plan.snapshot.id);
        _lastErrors[input.fileName] = _friendlyError(error);
      }
      _notify();
    }
    _batchTotal = 0;
    _activeBatchJobId = null;
    await reload();
  }

  Future<void> stopRemainingBatch() async {
    if (_batchTotal == 0) return;
    _batchCancelled = true;
    final active = _activeBatchJobId;
    final library = await _getLibrary();
    if (active != null) await cancel(active);
    for (var index = 0; index < _batchPlanIds.length; index++) {
      final id = _batchPlanIds[index];
      if (_batchProcessedIds.contains(id) || id == active) continue;
      await _cancelQueuedJob(library, id);
    }
    for (final job in await library.localImportJobs()) {
      if (_batchPlanIds.contains(job.id)) _upsertJob(job);
    }
    _notify();
  }

  Future<void> _cancelQueuedJob(ContentLibrary library, String id) =>
      _batchCancelFutures.putIfAbsent(id, () => library.cancelLocalImport(id));

  Future<void> setOptions(String id, LocalDocumentParseOptions options) async {
    _options[id] = options;
    try {
      final library = await _getLibrary();
      final job = await library.reparseLocalImport(id, options);
      _upsertJob(job);
      if (job.status == LocalImportStatus.awaitingConfirmation) {
        _lastErrors.remove(id);
        await _loadPreview(library, id);
      }
    } on Object catch (error) {
      _lastErrors[id] = _friendlyError(error);
    }
    _notify();
  }

  Future<void> commit(String id, {String? title, String? author}) async {
    try {
      final library = await _getLibrary();
      final result = await library.commitLocalImport(id, title: title, author: author);
      _upsertJob(result);
      final input = _retryInputs.remove(id);
      if (input != null) await LocalImportIngress.instance.releaseInput(input);
      _lastErrors.remove(id);
      await _refreshDocuments(library);
    } on Object catch (error) {
      _lastErrors[id] = _friendlyError(error);
    }
    _notify();
  }

  void updateMetadata(String id, {required String title, required String? author}) {
    _metadata[id] = (title: title, author: author);
  }

  Future<void> commitReadyJobs() async {
    final ready = _jobs.where((job) => job.status == LocalImportStatus.awaitingConfirmation).toList(growable: false);
    if (ready.isEmpty) return;
    _batchCurrent = 0;
    _batchTotal = ready.length;
    _batchCancelled = false;
    _notify();
    for (final job in ready) {
      if (_batchCancelled) break;
      final metadata = _metadata[job.id];
      _batchCurrent++;
      await commit(job.id, title: metadata?.title, author: metadata?.author);
    }
    _batchTotal = 0;
    _notify();
  }

  Future<void> cancel(String id) async {
    try {
      final library = await _getLibrary();
      await library.cancelLocalImport(id);
      final input = _retryInputs.remove(id);
      if (input != null) await LocalImportIngress.instance.releaseInput(input);
      _jobs = await library.localImportJobs();
    } on Object catch (error) {
      _lastErrors[id] = _friendlyError(error);
    }
    _notify();
  }

  Future<void> retry(String id) async {
    final input = _retryInputs[id];
    try {
      final library = await _getLibrary();
      if (!_jobs.any((candidate) => candidate.id == id)) await reload();
      final index = _jobs.indexWhere((candidate) => candidate.id == id);
      if (index < 0) throw const LocalDocumentException('task_missing');
      final current = _jobs[index];
      LocalImportSnapshot result;
      if (current.errorCode == 'bookshelf_full' || current.errorCode == 'disk_full') {
        result = await library.commitLocalImport(id, title: current.title, author: current.author);
      } else {
        final options = _options[id] ?? current.options;
        result = await library.reparseLocalImport(id, options);
        if (result.errorCode == 'reselect_file' && input != null) {
          acceptInputs(<LocalImportInput>[input]);
          await importSelected(options: options);
          return;
        }
      }
      _upsertJob(result);
      if (result.status == LocalImportStatus.awaitingConfirmation) {
        _lastErrors.remove(id);
        await _loadPreview(library, id);
        final retainedInput = _retryInputs.remove(id);
        if (retainedInput != null) await LocalImportIngress.instance.releaseInput(retainedInput);
      } else if (result.status == LocalImportStatus.failed || result.status == LocalImportStatus.needsAction) {
        _lastErrors[id] = _friendlyJobError(result);
      }
      _notify();
    } on Object catch (error) {
      _lastErrors[id] = _friendlyError(error);
      _notify();
    }
  }

  Future<void> _loadPreview(ContentLibrary library, String id) async {
    try {
      _previews[id] = await library.previewLocalImport(id);
      _covers[id] = await library.previewLocalImportCover(id);
    } on Object catch (error) {
      _lastErrors[id] = _friendlyError(error);
    }
    _notify();
  }

  Future<void> _refreshDocuments(ContentLibrary library) async {
    try {
      _replaceDocuments(await library.listLocalDocuments(includeRetained: true));
      _usageBytes = await library.localDocumentUsageBytes();
    } on Object catch (error) {
      _lastErrors['documents'] = _friendlyError(error);
    }
    _notify();
  }

  Future<int> collectGarbage() async {
    final freedBytes = await (await _getLibrary()).collectLocalDocumentGarbage();
    await reload();
    return freedBytes;
  }

  void _replaceDocuments(List<LibraryItem> documents) {
    if (_disposed) return;
    final changed =
        _documents.length != documents.length ||
        documents.indexed.any((entry) {
          final before = _documents[entry.$1];
          final after = entry.$2;
          return before.id.value != after.id.value || before.revision != after.revision || before.state != after.state;
        });
    _documents = documents;
    if (changed) _onLibraryChanged?.call();
  }

  void _upsertJob(LocalImportSnapshot job) {
    final index = _jobs.indexWhere((item) => item.id == job.id);
    if (index < 0) {
      _jobs = <LocalImportSnapshot>[job, ..._jobs];
    } else {
      _jobs = <LocalImportSnapshot>[..._jobs]..[index] = job;
    }
  }

  static bool _supported(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.txt') || lower.endsWith('.epub');
  }

  static String _friendlyJobError(LocalImportSnapshot job) => switch (job.errorCode) {
    'unsupported_format' => '仅支持 TXT 和 EPUB 文件',
    'file_too_large' => '文件超过 256 MiB 上限',
    'chapter_limit' => '章节数量超过支持上限',
    'bookshelf_full' => '书架已满，请移除书籍后重试',
    'disk_full' => '存储空间不足，请释放空间后重试',
    'import_queue_full' => '待处理导入已达到 100 项，请先确认或取消已有任务',
    'parser_crashed' => '解析被意外中断，可以重试',
    'encoding_required' => '无法确定 TXT 编码，请选择编码后重新解析',
    'unsupported_encoding' => '所选 TXT 编码不受支持，请更换编码',
    'reselect_file' => '请重新选择原文件后继续',
    'empty_document' => '文件没有可导入的正文',
    'epub_drm_unsupported' => '此 EPUB 受到 DRM 保护，无法导入',
    'epub_mixed_content_unsupported' => '暂不支持图文混排 EPUB，请选择纯文字或纯图片书籍',
    'epub_reparse_required' => '此 EPUB 需要重新解析，请在本地书籍详情中选择“重新解析”',
    'epub_fixed_layout' || 'epub_mixed_fixed_layout' || 'epub_vertical_layout' => '暂不支持此 EPUB 排版格式',
    'epub_source_size' || 'epub_entry_size' || 'epub_expanded_size' || 'epub_container_size' || 'epub_opf_size' => 'EPUB 内容超过支持的大小上限',
    'epub_zip_invalid' ||
    'epub_zip_directory_mismatch' ||
    'epub_zip_directory_truncated' ||
    'epub_crc' ||
    'epub_zip_directory_invalid' ||
    'epub_zip_entry_invalid' => 'EPUB 文件损坏，无法读取',
    String code when code.startsWith('epub_') => 'EPUB 内容结构不受支持或文件已损坏',
    _ => job.errorDetail ?? '导入失败（${job.errorCode ?? '未知原因'}）',
  };

  static String _friendlyError(Object error) => error is LocalDocumentException
      ? _friendlyJobError(
          LocalImportSnapshot(
            id: '',
            fileName: '',
            status: LocalImportStatus.failed,
            updatedAt: DateTime.now(),
            errorCode: error.code,
            errorDetail: error.detail,
          ),
        )
      : error is FileSystemException
      ? '无法读取所选文件，请检查访问权限或重新选择。'
      : error.toString().replaceFirst('Exception: ', '');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_eventsSubscription?.cancel());
    unawaited(_ingressSubscription?.cancel());
    super.dispose();
  }
}
