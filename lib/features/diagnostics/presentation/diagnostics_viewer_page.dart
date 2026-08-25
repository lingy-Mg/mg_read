/// 调试日志查看页面。
///
/// 职责：
/// - 分页展示 App 或 Runtime 的脱敏关键事件。
/// - 管理当前来源的有界详情捕获和按需附件读取。
///
/// 注意：
/// - App 与 Runtime 会话按当前来源隔离，切换失败不能影响另一侧日志。
/// - 页面销毁时必须停止自己创建的捕获会话，不能在 build() 中发起 IO。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';
import 'package:mg_read/features/diagnostics/presentation/widgets/diagnostics_viewer_controls.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

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
  static const DiagnosticsViewerSource _source = DiagnosticsViewerSource.app;
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
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _gateway = ref.read(diagnosticsViewerGatewayProvider);
    scheduleMicrotask(() {
      unawaited(_loadEvents(reset: true));
      unawaited(_changeCaptureMode(DiagnosticsDetailMode.memoryOnly));
    });
  }

  @override
  void dispose() {
    _generation += 1;
    final capture = _capture;
    if (capture != null) {
      unawaited(_gateway.stopCapture(capture).catchError((_) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '调试日志', onBack: widget.onBackRequested),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _loadEvents(reset: true),
                  child: CustomScrollView(
                    key: const Key('diagnostics-viewer-content'),
                    slivers: <Widget>[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.comfortable,
                          AppSpacing.regular,
                          AppSpacing.comfortable,
                          AppSpacing.page,
                        ),
                        sliver: SliverList.list(
                          children: <Widget>[
                            DiagnosticsViewerCapturePanel(
                              mode: _capture?.mode ?? DiagnosticsDetailMode.off,
                              busy: _captureBusy,
                              warningCode: _capture?.warningCode,
                              errorCode: _captureError,
                              onModeSelected: _changeCaptureMode,
                            ),
                            const SizedBox(height: AppSpacing.regular),
                            if (_loading)
                              const Padding(
                                padding: EdgeInsets.all(AppSpacing.page),
                                child: Center(child: CircularProgressIndicator(key: Key('diagnostics-viewer-loading'))),
                              )
                            else if (_loadError != null)
                              _LoadFailure(errorCode: _loadError!, onRetry: () => _loadEvents(reset: true))
                            else if (_events.isEmpty)
                              const _EmptyEvents()
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

  Future<void> _loadEvents({required bool reset}) async {
    if (!mounted) return;
    if (!reset && (_loadingMore || _nextCursor == null)) return;
    final generation = ++_generation;
    final source = _source;
    setState(() {
      if (reset) {
        _loading = true;
        _loadError = null;
        _events = const <DiagnosticsViewerEvent>[];
        _nextCursor = null;
        _expandedEvent = null;
        _details.clear();
        _detailErrors.clear();
        _previews.clear();
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = await _gateway.listEvents(source: source, cursor: reset ? null : _nextCursor);
      if (!mounted || generation != _generation || source != _source) return;
      setState(() {
        final combined = reset ? page.items : <DiagnosticsViewerEvent>[..._events, ...page.items];
        _events = List<DiagnosticsViewerEvent>.unmodifiable(combined.take(_maximumRetainedEvents));
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

  Future<void> _changeCaptureMode(DiagnosticsDetailMode mode) async {
    if (!mounted) return;
    if (_captureBusy || (_capture?.mode == mode && _capture?.source == _source)) {
      return;
    }
    setState(() {
      _captureBusy = true;
      _captureError = null;
    });
    final previous = _capture;
    if (previous != null) {
      try {
        await _gateway.stopCapture(previous);
      } on Object catch (error) {
        if (!mounted) return;
        setState(() {
          _captureBusy = false;
          _captureError = _viewerErrorCode(error);
        });
        return;
      }
      if (!mounted) return;
      _capture = null;
    }
    if (mode == DiagnosticsDetailMode.off) {
      setState(() {
        _captureBusy = false;
      });
      return;
    }
    try {
      final capture = await _gateway.startCapture(mode: mode, source: _source);
      if (!mounted) {
        unawaited(_gateway.stopCapture(capture).catchError((_) {}));
        return;
      }
      setState(() {
        _capture = capture;
        _captureBusy = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _captureError = _viewerErrorCode(error);
        _captureBusy = false;
      });
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

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.expanded,
    required this.loadingDetails,
    required this.previews,
    required this.loadingPreviews,
    required this.onToggle,
    required this.onPreview,
    this.details,
    this.detailError,
  });

  final String? detailError;
  final DiagnosticsViewerEventDetails? details;
  final DiagnosticsViewerEvent event;
  final bool expanded;
  final bool loadingDetails;
  final Set<String> loadingPreviews;
  final ValueChanged<DiagnosticsViewerAttachment> onPreview;
  final VoidCallback onToggle;
  final Map<String, String> previews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final severityColor = _severityColor(context, event.severity);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: ValueKey<String>('diagnostic-event-${event.identity}'),
            borderRadius: AppRadii.detailCard,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(color: severityColor.withValues(alpha: 0.12), borderRadius: AppRadii.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
                          child: Text(
                            event.severity.toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(color: severityColor, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Text(
                          event.eventName,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        _formatTimestamp(event.occurredAtUtcMicros),
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                      Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: tokens.mutedText),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  Text(event.summary, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    '${event.component} · ${event.phase}'
                    '${event.outcome == null ? '' : ' · ${event.outcome}'}'
                    '${event.durationMicros == null ? '' : ' · ${_formatDuration(event.durationMicros!)}'}'
                    '${event.attachmentCount == 0 ? '' : ' · ${event.attachmentCount} 个详情'}',
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...<Widget>[
            Divider(height: 1, color: tokens.divider),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: _EventDetails(
                details: details,
                loading: loadingDetails,
                errorCode: detailError,
                previews: previews,
                loadingPreviews: loadingPreviews,
                onPreview: onPreview,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventDetails extends StatelessWidget {
  const _EventDetails({
    required this.loading,
    required this.previews,
    required this.loadingPreviews,
    required this.onPreview,
    this.details,
    this.errorCode,
  });

  final DiagnosticsViewerEventDetails? details;
  final String? errorCode;
  final bool loading;
  final Set<String> loadingPreviews;
  final ValueChanged<DiagnosticsViewerAttachment> onPreview;
  final Map<String, String> previews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (errorCode != null) return Text('详情读取失败：$errorCode');
    final value = details;
    if (value == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('结构化字段', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.compact),
        _PlainTextPreview(text: value.attributesText),
        if (value.attachments.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text('详情附件', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.compact),
          ...value.attachments.map((attachment) {
            final preview = previews[attachment.identity];
            final loadingPreview = loadingPreviews.contains(attachment.identity);
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.compact),
              child: DecoratedBox(
                decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.control),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.compact),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(child: Text('${attachment.kind} · ${attachment.mediaType}', style: theme.textTheme.labelLarge)),
                          Text(
                            _formatBytes(attachment.storedByteLength),
                            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        '状态 ${attachment.captureState}'
                        '${attachment.truncationReason == null ? '' : ' · ${attachment.truncationReason}'}',
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                      const SizedBox(height: AppSpacing.compact),
                      OutlinedButton.icon(
                        onPressed: loadingPreview || attachment.storedByteLength == 0 ? null : () => onPreview(attachment),
                        icon: loadingPreview
                            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.visibility_outlined),
                        label: const Text('纯文本预览前 32 KiB'),
                      ),
                      if (preview != null) ...<Widget>[const SizedBox(height: AppSpacing.compact), _PlainTextPreview(text: preview)],
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _PlainTextPreview extends StatelessWidget {
  const _PlainTextPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.compact),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.control,
        border: Border.all(color: tokens.divider),
      ),
      child: SingleChildScrollView(
        child: SelectableText(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.errorCode, required this.onRetry});

  final String errorCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        children: <Widget>[
          const Icon(Icons.error_outline_rounded, size: 40),
          const SizedBox(height: AppSpacing.compact),
          Text('日志读取失败：$errorCode'),
          const SizedBox(height: AppSpacing.compact),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Text(
        '暂无可显示的关键日志。',
        key: const Key('diagnostics-viewer-empty'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
      ),
    );
  }
}

Color _severityColor(BuildContext context, String severity) {
  final tokens = AppThemeTokens.of(context);
  return switch (severity) {
    'fatal' || 'error' => Theme.of(context).colorScheme.error,
    'warn' => tokens.warning,
    'info' => tokens.success,
    _ => tokens.mutedText,
  };
}

String _formatTimestamp(int micros) {
  final value = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
      '${three(value.millisecond)}';
}

String _formatDuration(int micros) {
  if (micros < 1000) return '$micros µs';
  if (micros < 1000 * 1000) return '${(micros / 1000).toStringAsFixed(1)} ms';
  return '${(micros / (1000 * 1000)).toStringAsFixed(2)} s';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

String _viewerErrorCode(Object error) {
  if (error is DiagnosticsViewerException) return error.code;
  if (error is StateError) return 'invalid_state';
  if (error is TimeoutException) return 'timeout';
  return 'operation_failed';
}
