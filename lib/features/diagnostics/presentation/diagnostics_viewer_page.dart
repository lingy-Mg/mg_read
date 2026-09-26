/// 调试日志查看页面。
///
/// 职责：
/// - 默认展示当前进程的有界实时事件，并允许切换历史日志文件。
/// - 管理当前来源的有界详情捕获和按需附件读取。
/// - 集中提供数据源 Runtime 检查页开关与访问地址。
/// - 展示应用级临时记录状态，跨页面持续 15 分钟；文件保存独立控制并立即生效。
///
/// 注意：
/// - 文件列表不得加载事件；单文件损坏不能影响其他文件。
/// - 页面仅释放订阅；网关拥有捕获生命周期，不能在 build() 中发起 IO。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_activation.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_capture_preference_store.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';
import 'package:mg_read/features/diagnostics/presentation/widgets/diagnostics_viewer_controls.dart';
import 'package:mg_read/features/diagnostics/presentation/widgets/runtime_debug_panel.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

part 'widgets/diagnostics_viewer_log_widgets.dart';

/// Dedicated, bounded viewer for app and Runtime diagnostic TXT records.
class DiagnosticsViewerPage extends ConsumerStatefulWidget {
  const DiagnosticsViewerPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<DiagnosticsViewerPage> createState() => _DiagnosticsViewerPageState();
}

class _DiagnosticsViewerPageState extends ConsumerState<DiagnosticsViewerPage> {
  static const int _maximumRetainedEvents = 500;
  static const int _maximumRetainedPreviews = 8;

  late final DiagnosticsViewerGateway _gateway;
  late final DiagnosticsCapturePreferenceStore _capturePreferenceStore;
  DiagnosticsActivation? _activation;
  static const DiagnosticsViewerSource _source = DiagnosticsViewerSource.app;
  List<DiagnosticsViewerLogFile> _logFiles = const <DiagnosticsViewerLogFile>[];
  DiagnosticsViewerLogFile? _selectedLogFile;
  List<DiagnosticsViewerEvent> _events = const <DiagnosticsViewerEvent>[];
  final Map<String, DiagnosticsViewerEventDetails> _details = <String, DiagnosticsViewerEventDetails>{};
  final Set<String> _loadingDetails = <String>{};
  final Map<String, String> _detailErrors = <String, String>{};
  final Map<String, String> _previews = <String, String>{};
  final Set<String> _loadingPreviews = <String>{};
  String? _nextCursor;
  String? _expandedEvent;
  String? _loadError;
  String? _captureError;
  DiagnosticsViewerCapture? _capture;
  var _loading = true;
  var _loadingMore = false;
  var _captureBusy = false;
  var _diagnosticsEnabled = false;
  var _activationBusy = false;
  var _generation = 0;
  StreamSubscription<void>? _liveSubscription;
  Timer? _liveRefreshDebounce;
  StreamSubscription<void>? _captureSubscription;

  @override
  void initState() {
    super.initState();
    _gateway = ref.read(diagnosticsViewerGatewayProvider);
    _capture = _gateway.activeCapture;
    _captureSubscription = _gateway.watchCaptureChanges().listen((_) {
      if (!mounted) return;
      setState(() {
        _capture = _gateway.activeCapture;
      });
      _onLiveEvent(null);
    });
    _capturePreferenceStore = ref.read(diagnosticsCapturePreferenceStoreProvider);
    _activation = ref.read(diagnosticsActivationProvider);
    _liveSubscription = _gateway.watchLiveEvents().listen(_onLiveEvent);
    scheduleMicrotask(() {
      unawaited(_loadLifecycle());
    });
  }

  @override
  void dispose() {
    _generation += 1;
    unawaited(_captureSubscription?.cancel());
    _liveRefreshDebounce?.cancel();
    unawaited(_liveSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '问题诊断', onBack: widget.onBackRequested),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _loadLogFiles,
                  child: CustomScrollView(
                    key: const Key('diagnostics-viewer-content'),
                    slivers: <Widget>[
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.comfortable,
                          AppSpacing.regular,
                          AppSpacing.comfortable,
                          AppDetailMetrics.bottomNavigationContentBottomPadding + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        sliver: SliverList.list(
                          children: <Widget>[
                            DiagnosticsViewerRecordingPanel(
                              detailed: _capture != null,
                              saving: _diagnosticsEnabled,
                              busy: _activationBusy || _captureBusy || _loading,
                              onDetailedChanged: (enabled) => _changeCaptureMode(
                                enabled
                                    ? (_diagnosticsEnabled ? DiagnosticsDetailMode.persistToText : DiagnosticsDetailMode.memoryOnly)
                                    : DiagnosticsDetailMode.off,
                              ),
                              onSavingChanged: _changeDiagnosticsEnabled,
                              errorCode: _captureError,
                            ),
                            const SizedBox(height: AppSpacing.compact),
                            const ExpansionTile(
                              leading: Icon(Icons.developer_mode_rounded),
                              title: Text('数据源检查工具'),
                              children: [RuntimeDebugPanel()],
                            ),
                            const SizedBox(height: AppSpacing.regular),
                            _LogFilePicker(
                              files: _logFiles,
                              selectedFileId: _selectedLogFile?.fileId,
                              onSelected: _selectLogFile,
                              onDelete: _deleteSelectedLog,
                              onExport: _exportSelectedLog,
                            ),
                            const SizedBox(height: AppSpacing.regular),
                            if (_loading)
                              const Padding(
                                padding: EdgeInsets.all(AppSpacing.page),
                                child: Center(child: CircularProgressIndicator(key: Key('diagnostics-viewer-loading'))),
                              )
                            else if (_loadError != null)
                              _LoadFailure(errorCode: _loadError!, onRetry: () => _loadEvents(reset: true))
                            else if (_selectedLogFile == null)
                              const _SelectLogFile()
                            else if (_events.isEmpty)
                              _EmptyEvents(isLive: _selectedLogFile?.isLive ?? false)
                            else
                              ..._events.map(_buildEventCard),
                            if (!_loading && _nextCursor != null)
                              Padding(
                                padding: const EdgeInsets.only(top: AppSpacing.compact),
                                child: OutlinedButton.icon(
                                  key: const Key('diagnostics-load-more'),
                                  onPressed: _loadingMore ? null : () => _loadEvents(reset: false),
                                  icon: _loadingMore
                                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.expand_more_rounded),
                                  label: Text(_loadingMore ? '正在读取…' : '读取更早日志'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: ProfileDetailBottomBar(onSelected: widget.onDestinationRequested),
    );
  }

  Future<void> _loadLifecycle() async {
    try {
      final enabled = await _capturePreferenceStore.loadDiagnosticsEnabled();
      if (!mounted) return;
      setState(() {
        _diagnosticsEnabled = _activation?.enabledForCurrentRun ?? enabled;
        _loading = false;
      });
      await _loadLogFiles();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = _viewerErrorCode(error);
        _loading = false;
      });
    }
  }

  Future<void> _changeDiagnosticsEnabled(bool enabled) async {
    if (_activationBusy || _captureBusy) return;
    setState(() {
      _activationBusy = true;
      _captureError = null;
    });
    final wasDetailed = _capture != null;
    try {
      // Stop payload capture before closing file admission; switching modes
      // never silently starts a file writer from an in-memory capture.
      if (wasDetailed) await _changeCaptureMode(DiagnosticsDetailMode.off);
      if (_capture != null) return;
      final activation = _activation;
      if (enabled) {
        final active = activation == null ? true : await activation.enableForCurrentRun();
        if (!active) throw const DiagnosticsViewerException('file_recording_unavailable');
      } else {
        await activation?.disableForCurrentRun();
      }
      if (activation == null) await _capturePreferenceStore.saveDiagnosticsEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _diagnosticsEnabled = enabled;
      });
      if (wasDetailed) await _changeCaptureMode(enabled ? DiagnosticsDetailMode.persistToText : DiagnosticsDetailMode.memoryOnly);
      await _loadLogFiles();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _diagnosticsEnabled = _activation?.enabledForCurrentRun ?? _diagnosticsEnabled;
          _captureError = _viewerErrorCode(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _activationBusy = false;
        });
      }
    }
  }

  Future<void> _loadLogFiles() async {
    final files = await _gateway.listLogFiles();
    if (!mounted) return;
    final previousFileId = _selectedLogFile?.fileId;
    DiagnosticsViewerLogFile? selected;
    for (final file in files) {
      if (file.fileId == previousFileId) {
        selected = file;
        break;
      }
    }
    selected ??= files.isEmpty ? null : files.first;
    setState(() {
      _logFiles = files;
      _selectedLogFile = selected;
      _events = const <DiagnosticsViewerEvent>[];
      _nextCursor = null;
      _loading = false;
    });
    if (selected != null) await _loadEvents(reset: true);
  }

  Future<void> _selectLogFile(DiagnosticsViewerLogFile file) async {
    if (_selectedLogFile?.fileId == file.fileId) return;
    setState(() {
      _selectedLogFile = file;
    });
    await _loadEvents(reset: true);
  }

  Future<void> _deleteSelectedLog() async {
    final file = _selectedLogFile;
    if (file == null || file.isCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份记录？'),
        content: Text('${_formatFileDate(file.startedAtUtcMicros)}\n删除后无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _gateway.deleteLogFile(file.fileId);
      await _loadLogFiles();
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = _viewerErrorCode(error));
    }
  }

  Future<void> _exportSelectedLog() async {
    final file = _selectedLogFile;
    if (file == null) return;
    try {
      final result = await _gateway.exportLogFile(file.fileId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出 ${result.byteLength} 字节')));
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = _viewerErrorCode(error));
    }
  }

  Widget _buildEventCard(DiagnosticsViewerEvent event) {
    final expanded = _expandedEvent == event.identity;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.compact),
      child: _EventCard(
        event: event,
        expanded: expanded,
        details: _details[event.identity],
        loadingDetails: _loadingDetails.contains(event.identity),
        detailError: _detailErrors[event.identity],
        previews: _previews,
        loadingPreviews: _loadingPreviews,
        onToggle: () => _toggleEvent(event),
        onPreview: _loadPreview,
      ),
    );
  }

  Future<void> _loadEvents({required bool reset, bool passive = false}) async {
    if (!mounted) return;
    final selected = _selectedLogFile;
    if (selected == null) return;
    if (!reset && (_loadingMore || _nextCursor == null)) return;
    final generation = ++_generation;
    final source = _source;
    setState(() {
      if (reset) {
        _loading = !passive;
        _loadError = null;
        if (!passive) _events = const <DiagnosticsViewerEvent>[];
        _nextCursor = null;
        if (!passive) {
          _expandedEvent = null;
          _details.clear();
          _detailErrors.clear();
          _previews.clear();
        }
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await _gateway.listEvents(source: source, logFileId: selected.fileId, cursor: reset ? null : _nextCursor);
      if (!mounted || generation != _generation || source != _source || _selectedLogFile?.fileId != selected.fileId) return;
      setState(() {
        final combined = reset ? page.items : <DiagnosticsViewerEvent>[..._events, ...page.items];
        _events = List<DiagnosticsViewerEvent>.unmodifiable(combined.take(_maximumRetainedEvents));
        final visibleIds = _events.map((event) => event.identity).toSet();
        _details.removeWhere((identity, _) => !visibleIds.contains(identity));
        _detailErrors.removeWhere((identity, _) => !visibleIds.contains(identity));
        if (!visibleIds.contains(_expandedEvent)) _expandedEvent = null;
        final attachmentIds = _details.values.expand((detail) => detail.attachments).map((attachment) => attachment.identity).toSet();
        _previews.removeWhere((identity, _) => !attachmentIds.contains(identity));
        _nextCursor = combined.length >= _maximumRetainedEvents ? null : page.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation || source != _source) return;
      setState(() {
        _loadError = _viewerErrorCode(error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _onLiveEvent(void _) {
    if (!mounted || _selectedLogFile?.isLive != true) return;
    if (_liveRefreshDebounce?.isActive ?? false) return;
    _liveRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || _selectedLogFile?.isLive != true || _loading || _loadingMore) return;
      unawaited(_loadEvents(reset: true, passive: true));
    });
  }

  Future<void> _changeCaptureMode(DiagnosticsDetailMode mode) async {
    if (!mounted || _captureBusy || (_capture?.mode ?? DiagnosticsDetailMode.off) == mode) return;
    if (mode == DiagnosticsDetailMode.persistToText && !_diagnosticsEnabled) return;
    setState(() {
      _captureBusy = true;
      _captureError = null;
    });
    try {
      final previous = _capture;
      if (previous != null) await _gateway.stopCapture(previous);
      _capture = null;
      if (!mounted) return;
      if (mode != DiagnosticsDetailMode.off) {
        final capture = await _gateway.startCapture(mode: mode, source: _source);
        if (!mounted) return;
        _capture = capture;
      }
      await _loadEvents(reset: true, passive: true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _captureError = _viewerErrorCode(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _captureBusy = false;
        });
      }
    }
  }

  Future<void> _toggleEvent(DiagnosticsViewerEvent event) async {
    if (_expandedEvent == event.identity) {
      setState(() {
        _expandedEvent = null;
      });
      return;
    }
    setState(() {
      _expandedEvent = event.identity;
    });
    if (_details.containsKey(event.identity) || _loadingDetails.contains(event.identity)) {
      return;
    }
    setState(() {
      _loadingDetails.add(event.identity);
      _detailErrors.remove(event.identity);
    });
    try {
      final details = await _gateway.loadEventDetails(event);
      if (!mounted) return;
      if (_selectedLogFile?.fileId != event.logFileId || !_events.any((item) => item.identity == event.identity)) {
        _loadingDetails.remove(event.identity);
        return;
      }
      setState(() {
        _loadingDetails.remove(event.identity);
        _details[event.identity] = details;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDetails.remove(event.identity);
        _detailErrors[event.identity] = _viewerErrorCode(error);
      });
    }
  }

  Future<void> _loadPreview(DiagnosticsViewerAttachment attachment) async {
    if (_previews.containsKey(attachment.identity) || _loadingPreviews.contains(attachment.identity)) {
      return;
    }
    setState(() {
      _loadingPreviews.add(attachment.identity);
    });
    try {
      final preview = await _gateway.readAttachmentPreview(attachment);
      if (!mounted) return;
      setState(() {
        _loadingPreviews.remove(attachment.identity);
        if (_previews.length >= _maximumRetainedPreviews) {
          _previews.remove(_previews.keys.first);
        }
        _previews[attachment.identity] = preview;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingPreviews.remove(attachment.identity);
        _previews[attachment.identity] = '预览失败：${_viewerErrorCode(error)}';
      });
    }
  }
}
