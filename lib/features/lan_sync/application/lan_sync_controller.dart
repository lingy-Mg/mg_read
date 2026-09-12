/// 局域网同步状态控制器。
///
/// 职责：
/// - 编排发送、接收、预览、传输和应用阶段。
/// - 管理同步会话资源与诊断终态。
///
/// 注意：
/// - 会话代际用于丢弃过期异步结果。
/// - 网络和流资源释放必须是尽力操作，不能把清理异常泄漏到应用边界。
/// - 扫码预览至清理完成持有共享网关会话，避免自动同步覆盖或取消当前导入。
/// - 亮屏按实际异步操作持有至清理完成；等待扫码、配对确认和内容选择时不占用。
///
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_session.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_screen_awake.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';

final lanSyncControllerProvider = NotifierProvider.autoDispose<LanSyncController, LanSyncViewState>(LanSyncController.new);

final class LanSyncViewState {
  const LanSyncViewState({
    this.role,
    this.phase = LanSyncPhase.idle,
    this.message = '选择发送或接收开始同步',
    this.connectionOffer,
    this.pairingCode,
    this.manifest,
    this.preview,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.result,
    this.errorCode,
  });

  final LanSyncRole? role;
  final LanSyncPhase phase;
  final String message;
  final LanSyncConnectionOffer? connectionOffer;
  final String? pairingCode;
  final LanSyncManifest? manifest;
  final LanSyncImportPreview? preview;
  final int transferredBytes;
  final int totalBytes;
  final LanSyncApplyResult? result;
  final String? errorCode;

  bool get busy => switch (phase) {
    LanSyncPhase.preparing ||
    LanSyncPhase.discovering ||
    LanSyncPhase.waitingForPeer ||
    LanSyncPhase.pairing ||
    LanSyncPhase.transferring ||
    LanSyncPhase.applying => true,
    _ => false,
  };

  double? get progress => totalBytes <= 0 ? null : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

final class LanSyncController extends Notifier<LanSyncViewState> {
  LanSyncSenderService? _sender;
  LanSyncReceiverConnection? _receiver;
  StreamSubscription<LanSyncSenderEvent>? _senderSubscription;
  DiagnosticSpanHandle? _span;
  final Stopwatch _sessionStopwatch = Stopwatch();
  bool _senderTransferRecorded = false;
  int _generation = 0;
  LanSyncSession? _session;
  Future<void>? _cleanupFuture;
  LanSyncScreenAwake? _senderAwake;

  @override
  LanSyncViewState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_disposeResources());
    });
    return const LanSyncViewState();
  }

  Future<void> startSending() => LanSyncScreenAwake.run(_startSending);

  Future<void> _startSending() async {
    if (state.busy) return;
    final generation = ++_generation;
    await _disposeResources(completeSpan: true);
    if (!_isCurrent(generation)) return;
    if (!_acquireSession()) return;
    state = const LanSyncViewState(role: LanSyncRole.sender, phase: LanSyncPhase.preparing, message: '正在准备插件与书架清单');
    _startSpan(LanSyncRole.sender);
    if (!await _ensureLocalNetwork(generation)) return;
    _recordStage('manifest_prepare_started');
    try {
      final session = _session!;
      final manifest = await session.run((gateway) => gateway.createManifest());
      if (!_isCurrent(generation)) return;
      final sender = await LanSyncSenderService.start(
        manifest: manifest,
        openPlugin: (plugin) => session.run((gateway) => gateway.openPluginArchive(plugin)),
      );
      if (!_isCurrent(generation)) {
        await sender.close();
        return;
      }
      _sender = sender;
      _senderSubscription = sender.events.listen(
        _onSenderEvent,
        onError: (Object error, StackTrace stackTrace) => _onAsyncFailure('sender_event', error, stackTrace),
      );
      final connectionOffer = sender.addresses.isEmpty
          ? null
          : LanSyncConnectionOffer(sessionId: sender.sessionId, port: sender.port, addresses: sender.addresses);
      state = LanSyncViewState(
        role: LanSyncRole.sender,
        phase: LanSyncPhase.waitingForPeer,
        message: '等待接收设备连接',
        connectionOffer: connectionOffer,
        manifest: manifest,
        totalBytes: manifest.plugins.where((item) => item.transferable).fold<int>(0, (sum, item) => sum + item.bytes),
      );
      _recordStage('sender_ready');
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('prepare', error), errorLocation: 'prepare', error: error, stackTrace: stackTrace);
      }
    }
  }

  Future<void> startReceiving() => LanSyncScreenAwake.run(_startReceiving);

  Future<void> _startReceiving() async {
    if (state.busy) return;
    final generation = ++_generation;
    await _disposeResources(completeSpan: true);
    if (!_isCurrent(generation)) return;
    if (!_acquireSession()) return;
    state = const LanSyncViewState(role: LanSyncRole.receiver, phase: LanSyncPhase.discovering, message: '请扫描发送设备显示的二维码');
    _startSpan(LanSyncRole.receiver);
    if (!await _ensureLocalNetwork(generation)) return;
    _recordStage('qr_scan_waiting');
  }

  Future<void> connectOffer(LanSyncConnectionOffer offer) async {
    await _connectOffer(offer);
  }

  Future<void> _connectOffer(LanSyncConnectionOffer offer) => LanSyncScreenAwake.run(() => _connectOfferAwake(offer));

  Future<void> _connectOfferAwake(LanSyncConnectionOffer offer) async {
    if (state.role != LanSyncRole.receiver || state.phase != LanSyncPhase.discovering) return;
    final generation = ++_generation;
    if (!_isCurrent(generation)) return;
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.preparing,
      message: offer.addresses.length == 1 ? '正在连接发送设备' : '正在测试二维码中的 ${offer.addresses.length} 个局域网地址',
    );
    try {
      final expiresAt = DateTime.now().toUtc().add(lanSyncSessionLifetime);
      final receiver = await LanSyncReceiverConnection.connectAny(<LanSyncPeer>[
        for (final address in offer.addresses)
          LanSyncPeer(sessionId: offer.sessionId, label: '二维码中的发送设备', address: address, port: offer.port, expiresAtUtc: expiresAt),
      ]);
      if (!_isCurrent(generation)) {
        await receiver.close();
        return;
      }
      _receiver = receiver;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.pairing,
        message: '请核对两台设备显示的确认码',
        pairingCode: receiver.pairingCode,
      );
      _recordStage('pairing_ready');
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('connect', error), errorLocation: 'connect', error: error, stackTrace: stackTrace);
      }
    }
  }

  Future<void> confirmReceiverPairing() => LanSyncScreenAwake.run(_confirmReceiverPairing);

  Future<void> _confirmReceiverPairing() async {
    final receiver = _receiver;
    if (receiver == null || state.phase != LanSyncPhase.pairing) return;
    final generation = ++_generation;
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.previewing,
      message: '正在读取并检查同步清单',
      pairingCode: state.pairingCode,
    );
    _recordStage('manifest_preview_started');
    try {
      final manifest = await receiver.confirmAndReadManifest();
      if (!_isCurrent(generation)) return;
      final preview = await _session!.run((gateway) => gateway.previewImport(manifest, force: true));
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.previewing,
        message: '将强制覆盖本机同名插件、书架和阅读进度',
        manifest: manifest,
        preview: preview,
        totalBytes: preview.recommendedPluginIds.fold<int>(
          0,
          (sum, id) => sum + manifest.plugins.firstWhere((item) => item.id == id).bytes,
        ),
      );
      _recordStage('manifest_preview_completed');
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('preview', error), errorLocation: 'preview', error: error, stackTrace: stackTrace);
      }
    }
  }

  void chooseConflict(String identity, LanSyncConflictChoice choice) {
    final preview = state.preview;
    if (preview == null) return;
    final next = preview.withConflictChoice(identity, choice);
    state = LanSyncViewState(
      role: state.role,
      phase: state.phase,
      message: state.message,
      manifest: state.manifest,
      preview: next,
      totalBytes: state.totalBytes,
    );
  }

  void choosePlugin(String pluginId, bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null || !_canSelectPlugin(manifest, preview, pluginId)) return;
    final selectedIds = <String>{...preview.selectedPluginIds};
    if (selected) {
      selectedIds.add(pluginId);
    } else {
      selectedIds.remove(pluginId);
    }
    final forceIds = <String>{
      ...preview.forceUpgradePluginIds,
      if (selected && preview.pluginPlans[pluginId] == LanSyncPluginPlanState.sameVersion) pluginId,
    }..removeWhere((id) => !selectedIds.contains(id));
    final next = preview.withSelection(pluginIds: selectedIds, forceUpgradeIds: forceIds);
    state = _withPreviewSelection(next, manifest);
  }

  void chooseShelfItem(String identity, bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null || !manifest.shelfItems.any((item) => item.identity == identity)) return;
    final selectedIds = <String>{...preview.selectedShelfItemIds};
    if (selected) {
      selectedIds.add(identity);
    } else {
      selectedIds.remove(identity);
    }
    final next = preview.withSelection(shelfItemIds: selectedIds);
    state = _withPreviewSelection(next, manifest);
  }

  void chooseAllShelfItems(bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null) return;
    final next = preview.withSelection(
      shelfItemIds: selected ? <String>{for (final item in manifest.shelfItems) item.identity} : const <String>{},
    );
    state = _withPreviewSelection(next, manifest);
  }

  void chooseAllPlugins(bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null) return;
    final selectable = <String>{
      for (final plugin in manifest.plugins)
        if (plugin.transferable &&
            (preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.missing ||
                preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.upgrade ||
                (preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.sameVersion &&
                    plugin.provenance == LanSyncPluginProvenance.installed)))
          plugin.id,
    };
    final forceIds = <String>{
      if (selected)
        for (final id in selectable)
          if (preview.pluginPlans[id] == LanSyncPluginPlanState.sameVersion) id,
    };
    final next = preview.withSelection(
      pluginIds: selected ? selectable : const <String>{},
      forceUpgradeIds: selected ? forceIds : const <String>{},
    );
    state = _withPreviewSelection(next, manifest);
  }

  void chooseAllContent(bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null) return;
    final pluginIds = <String>{
      for (final plugin in manifest.plugins)
        if (plugin.transferable &&
            (preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.missing ||
                preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.upgrade ||
                (preview.pluginPlans[plugin.id] == LanSyncPluginPlanState.sameVersion &&
                    plugin.provenance == LanSyncPluginProvenance.installed)))
          plugin.id,
    };
    final next = preview.withSelection(
      pluginIds: selected ? pluginIds : const <String>{},
      shelfItemIds: selected ? <String>{for (final item in manifest.shelfItems) item.identity} : const <String>{},
      forceUpgradeIds: selected
          ? <String>{
              for (final id in pluginIds)
                if (preview.pluginPlans[id] == LanSyncPluginPlanState.sameVersion) id,
            }
          : const <String>{},
    );
    state = _withPreviewSelection(next, manifest);
  }

  LanSyncViewState _withPreviewSelection(LanSyncImportPreview preview, LanSyncManifest manifest) => LanSyncViewState(
    role: state.role,
    phase: state.phase,
    message: state.message,
    connectionOffer: state.connectionOffer,
    pairingCode: state.pairingCode,
    manifest: manifest,
    preview: preview,
    transferredBytes: state.transferredBytes,
    totalBytes: _selectedPluginBytes(manifest, preview.selectedPluginIds),
    result: state.result,
  );

  Future<void> beginImport() => LanSyncScreenAwake.run(_beginImport);

  Future<void> _beginImport() async {
    final receiver = _receiver;
    final manifest = state.manifest;
    final preview = state.preview;
    if (receiver == null || manifest == null || preview == null || state.phase != LanSyncPhase.previewing || _session == null) return;
    final session = _session!;
    final generation = ++_generation;
    final selectedPluginIds = preview.selectedPluginIds;
    final selectedShelfItemIds = preview.selectedShelfItemIds;
    if (!preview.hasSelection) return;
    final selectedManifest = manifest.selectShelfItems(selectedShelfItemIds);
    final progressClock = Stopwatch()..start();
    var lastProgressAtMicros = -100000;
    void updateTransferProgress(String message, int completed, int total) {
      if (!_isCurrent(generation)) return;
      final nowMicros = progressClock.elapsedMicroseconds;
      final stageChanged = state.message != message;
      if (!stageChanged && completed != total && nowMicros - lastProgressAtMicros < 100000) return;
      lastProgressAtMicros = nowMicros;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.transferring,
        message: message,
        manifest: manifest,
        preview: preview,
        transferredBytes: completed,
        totalBytes: total,
      );
    }

    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.transferring,
      message: selectedPluginIds.isEmpty ? '正在应用书架数据' : '正在传输插件',
      manifest: manifest,
      preview: preview,
      totalBytes: state.totalBytes,
    );
    _recordStage('plugin_import_prepare_started');
    try {
      await session.run(
        (gateway) => gateway.preparePluginImports(<LanSyncPluginDescriptor>[
          for (final plugin in manifest.plugins)
            if (selectedPluginIds.contains(plugin.id)) plugin,
        ], forceUpgradePluginIds: preview.forceUpgradePluginIds),
      );
      if (!_isCurrent(generation)) return;
      _recordStage('plugin_transport_started');
      await receiver.receivePlugins(
        pluginIds: selectedPluginIds,
        shelfItemIds: selectedShelfItemIds,
        importPlugin: (plugin, bytes) {
          updateTransferProgress('正在写入${plugin.displayName ?? plugin.id}数据源', state.transferredBytes, state.totalBytes);
          return session.run((gateway) => gateway.importPluginArchive(plugin, bytes));
        },
        onVerificationProgress: (plugin, completed, total) {
          updateTransferProgress('正在校验${plugin.displayName ?? plugin.id}数据源', completed, total);
        },
        onWriteProgress: (plugin, completed, total) {
          updateTransferProgress('正在写入${plugin.displayName ?? plugin.id}数据源', completed, total);
        },
        onProgress: (completed, total) {
          updateTransferProgress('正在传输插件', completed, total);
        },
        onPluginBytesReceived: () {
          if (!_isCurrent(generation)) return;
          _recordStage('plugin_bytes_received');
        },
      );
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.transferring,
        message: '正在完成插件安装',
        manifest: manifest,
        preview: preview,
        transferredBytes: state.transferredBytes,
        totalBytes: state.totalBytes,
      );
      _recordStage('plugin_transport_completed');
      _recordStage('plugin_finalize_started');
      final pluginResult = await session.run((gateway) => gateway.finishPluginImports());
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.applying,
        message: '正在写入书架和阅读进度',
        manifest: manifest,
        preview: preview,
        transferredBytes: state.transferredBytes,
        totalBytes: state.totalBytes,
      );
      _recordStage('plugin_finalize_completed');
      _recordStage('library_apply_started');
      final result = await session.run(
        (gateway) => gateway.applyImport(
          manifest: selectedManifest,
          conflictChoices: <String, LanSyncConflictChoice>{for (final conflict in preview.conflicts) conflict.identity: conflict.choice},
          availablePluginIds: pluginResult.availablePluginIds,
          pluginResult: pluginResult,
          force: true,
        ),
      );
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.completed,
        message: pluginResult.failed > 0 ? '同步部分完成，部分插件安装失败，请查看结果后重试' : '局域网同步完成',
        errorCode: pluginResult.failed > 0 ? pluginResult.failureCode ?? 'lan_sync_plugin_import_failed' : null,
        manifest: manifest,
        result: result,
        transferredBytes: state.transferredBytes,
        totalBytes: state.totalBytes,
      );
      _recordStage('library_apply_completed');
      _completeSpan(pluginResult.failed > 0 ? 'error' : 'success', errorCode: pluginResult.failureCode);
      await _disposeResources();
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('import', error), errorLocation: 'import', error: error, stackTrace: stackTrace);
      }
    }
  }

  void _onSenderEvent(LanSyncSenderEvent event) {
    if (state.role != LanSyncRole.sender || state.phase == LanSyncPhase.cancelled || state.phase == LanSyncPhase.failed) {
      return;
    }
    switch (event) {
      case LanSyncSenderActivity(:final active):
        if (active) {
          _senderAwake ??= LanSyncScreenAwake();
        } else {
          unawaited(_senderAwake?.close());
          _senderAwake = null;
        }
      case LanSyncSenderReady():
        break;
      case LanSyncSenderPairing(:final code):
        state = LanSyncViewState(
          role: LanSyncRole.sender,
          phase: LanSyncPhase.pairing,
          message: '请核对接收设备上的确认码',
          connectionOffer: state.connectionOffer,
          pairingCode: code,
          manifest: state.manifest,
          totalBytes: state.totalBytes,
        );
        _recordStage('pairing_ready');
      case LanSyncSenderProgress(:final completedBytes, :final totalBytes):
        state = LanSyncViewState(
          role: LanSyncRole.sender,
          phase: LanSyncPhase.transferring,
          message: '正在发送插件与书架清单',
          connectionOffer: state.connectionOffer,
          manifest: state.manifest,
          transferredBytes: completedBytes,
          totalBytes: totalBytes,
        );
        if (!_senderTransferRecorded) {
          _senderTransferRecorded = true;
          _recordStage('plugin_transport_started');
        }
      case LanSyncSenderDone():
        state = LanSyncViewState(
          role: LanSyncRole.sender,
          phase: LanSyncPhase.completed,
          message: '发送完成',
          manifest: state.manifest,
          transferredBytes: state.transferredBytes,
          totalBytes: state.totalBytes,
        );
        _recordStage('plugin_transport_completed');
        _completeSpan('success');
        unawaited(_disposeResources());
      case LanSyncSenderFailed(:final code, :final error, :final stackTrace):
        _fail(code, errorLocation: 'sender_transport', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> cancel() async {
    _generation++;
    _recordStage('cancel_requested');
    _completeSpan('cancelled');
    await _disposeResources();
    state = const LanSyncViewState(phase: LanSyncPhase.cancelled, message: '同步已取消');
  }

  void reset() {
    _generation++;
    unawaited(_disposeResources(completeSpan: true));
    state = const LanSyncViewState();
  }

  void _fail(String code, {bool keepRole = false, String? errorLocation, Object? error, StackTrace? stackTrace}) {
    _generation++;
    _recordStage('failed');
    _completeSpan(
      'error',
      errorCode: code,
      errorLocation: errorLocation,
      errorText: error == null ? null : _technicalErrorText(error),
      stackTrace: stackTrace,
    );
    final role = keepRole ? state.role : null;
    unawaited(_disposeResources());
    state = LanSyncViewState(role: role, phase: LanSyncPhase.failed, message: lanSyncFailureMessage(code), errorCode: code);
  }

  Future<bool> _ensureLocalNetwork(int generation) async {
    var available = false;
    try {
      available = await ref.read(lanSyncNetworkEnvironmentProvider).isLocalNetworkAvailable();
    } on Object {
      available = false;
    }
    if (!_isCurrent(generation)) return false;
    if (available) return true;
    _recordStage('network_unavailable');
    _fail(Platform.isAndroid ? 'lan_sync_wifi_required' : 'lan_sync_local_network_unavailable');
    return false;
  }

  void _startSpan(LanSyncRole role) {
    _sessionStopwatch
      ..reset()
      ..start();
    _senderTransferRecorded = false;
    try {
      final diagnostics = ref.read(diagnosticsManagerProvider);
      _span = diagnostics.startSpan(
        AppDiagnosticEvents.lanSyncSession,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'role': DiagnosticValue.string(role.name),
          'stage': DiagnosticValue.string('start'),
        }),
      );
    } on Object {
      _span = null;
    }
  }

  void _completeSpan(String resultState, {String? errorCode, String? errorLocation, String? errorText, StackTrace? stackTrace}) {
    final span = _span;
    if (span == null) return;
    _span = null;
    final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
      'stage': DiagnosticValue.string('terminal'),
      'resultState': DiagnosticValue.string(resultState),
      if (state.manifest case final manifest?) ...<String, DiagnosticValue>{
        'pluginCount': DiagnosticValue.int64(manifest.plugins.length),
        'itemCount': DiagnosticValue.int64(manifest.shelfItems.length),
        'skippedItemCount': DiagnosticValue.int64(manifest.skippedShelfItems),
      },
      'bytes': DiagnosticValue.int64(state.transferredBytes),
      if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
      if (errorLocation != null) 'errorLocation': DiagnosticValue.string(errorLocation),
      if (errorText != null) 'errorText': DiagnosticValue.string(errorText),
      if (stackTrace != null) 'stackTrace': DiagnosticValue.string(stackTrace.toString()),
    });
    try {
      if (errorCode?.contains('timeout') ?? false) {
        span.timeout(attributes: attributes);
      } else if (resultState == 'error') {
        span.fail(attributes: attributes);
      } else if (resultState == 'cancelled') {
        span.cancel(attributes: attributes);
      } else {
        span.complete(attributes: attributes);
      }
    } on Object {
      // Diagnostics are best-effort and never change the sync result.
    } finally {
      _sessionStopwatch.stop();
    }
  }

  void _recordStage(String stage) {
    final span = _span;
    final role = state.role;
    if (span == null || role == null) return;
    try {
      ref
          .read(diagnosticsManagerProvider)
          .emit(
            AppDiagnosticEvents.lanSyncStage,
            traceContext: span.traceContext,
            attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
              'role': DiagnosticValue.string(role.name),
              'stage': DiagnosticValue.string(stage),
              'bytes': DiagnosticValue.int64(state.transferredBytes),
              'elapsedMicros': DiagnosticValue.int64(_sessionStopwatch.elapsedMicroseconds),
            }),
          );
    } on Object {
      // Diagnostics must not change the user-visible synchronization result.
    }
  }

  void _onAsyncFailure(String stage, Object error, StackTrace stackTrace) {
    if (state.phase == LanSyncPhase.cancelled || state.phase == LanSyncPhase.failed) {
      return;
    }
    _fail(_failureCodeFor(stage, error), errorLocation: stage, error: error, stackTrace: stackTrace);
  }

  bool _acquireSession() {
    _session = ref.read(lanSyncSessionCoordinatorProvider).tryAcquire(ref.read(lanSyncGatewayProvider));
    if (_session != null) return true;
    state = LanSyncViewState(
      phase: LanSyncPhase.failed,
      errorCode: 'lan_sync_peer_busy',
      message: lanSyncFailureMessage('lan_sync_peer_busy'),
    );
    return false;
  }

  Future<void> _disposeResources({bool completeSpan = false}) {
    if (completeSpan) _completeSpan('cancelled');
    return _cleanupFuture ??= _disposeResourcesOnce().whenComplete(() => _cleanupFuture = null);
  }

  Future<void> _disposeResourcesOnce() async {
    await LanSyncScreenAwake.run(_disposeResourcesAwake);
  }

  Future<void> _disposeResourcesAwake() async {
    final senderAwake = _senderAwake;
    _senderAwake = null;
    final session = _session;
    _session = null;
    final senderSubscription = _senderSubscription;
    _senderSubscription = null;
    try {
      await senderSubscription?.cancel();
    } on Object {
      // 释放阶段不能覆盖同步会话本身的结果。
    }

    final sender = _sender;
    _sender = null;
    try {
      await sender?.close();
    } on Object {
      // 释放阶段不能覆盖同步会话本身的结果。
    }

    final receiver = _receiver;
    _receiver = null;
    try {
      await receiver?.close();
    } on Object {
      // 释放阶段不能覆盖同步会话本身的结果。
    }
    await session?.close();
    await senderAwake?.close();
  }

  bool _isCurrent(int generation) => generation == _generation;
}

bool _canSelectPlugin(LanSyncManifest manifest, LanSyncImportPreview preview, String pluginId) {
  LanSyncPluginDescriptor? plugin;
  for (final item in manifest.plugins) {
    if (item.id == pluginId) {
      plugin = item;
      break;
    }
  }
  if (plugin == null || !plugin.transferable) return false;
  final plan = preview.pluginPlans[pluginId];
  return plan == LanSyncPluginPlanState.missing ||
      plan == LanSyncPluginPlanState.upgrade ||
      (plan == LanSyncPluginPlanState.sameVersion && plugin.provenance == LanSyncPluginProvenance.installed);
}

/// Converts LAN failure codes into user-facing copy.
String lanSyncFailureMessage(String code) => switch (code) {
  'lan_sync_peer_busy' => '另一项局域网同步正在进行，请完成或取消后重试',
  'lan_sync_wifi_required' => '手机未连接 Wi-Fi，已停止局域网同步',
  'lan_sync_local_network_unavailable' => '未检测到可用局域网，请检查 Wi-Fi 或网线连接',
  'lan_sync_address_not_private' => '只能连接同一私有局域网内的设备',
  'lan_sync_connect_failed' => '连接失败，请确认两台设备在同一网络',
  'lan_sync_manifest_invalid' => '同步清单内容无效或版本不兼容，请查看 Debug 控制台中的具体原因',
  'lan_sync_prepare_manifest_invalid' => '本机同步清单包含不兼容数据，请查看 Debug 控制台中的具体原因',
  'lan_sync_preview_failed' => '同步清单无法读取或版本不兼容',
  'lan_sync_import_failed' => '导入未完成，本机原有书架不会被删除',
  'lan_sync_import_$bookshelfCapacityExceededCode' => '书架已满，请先清理书籍',
  'lan_sync_timeout' => '等待确认超时，请重新开始同步',
  _ => '局域网同步失败，请重试',
};

String _failureCodeFor(String stage, Object error) {
  if (error is LanSyncTransportException) return error.code;
  if (error is LanSyncGatewayException) return 'lan_sync_${stage}_${error.code}';
  if (error is TimeoutException) return 'lan_sync_timeout';
  return 'lan_sync_${stage}_failed';
}

String _technicalErrorText(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  final value = text.startsWith('${error.runtimeType}:') ? text : '${error.runtimeType}: $text';
  return value.length <= 1024 ? value : '${value.substring(0, 1023)}…';
}

int _selectedPluginBytes(LanSyncManifest manifest, Set<String> selectedPluginIds) =>
    manifest.plugins.where((plugin) => selectedPluginIds.contains(plugin.id)).fold<int>(0, (sum, plugin) => sum + plugin.bytes);
