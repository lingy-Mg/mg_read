/// 局域网同步状态控制器。
///
/// 职责：
/// - 编排发送、接收、预览、传输和应用阶段。
/// - 管理同步会话资源与诊断终态。
///
/// 注意：
/// - 会话代际用于丢弃过期异步结果。
/// - 网络和流资源释放必须是尽力操作，不能把清理异常泄漏到应用边界。
///
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
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
    this.peers = const <LanSyncPeer>[],
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
  final List<LanSyncPeer> peers;
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
  LanSyncDiscoveryService? _discovery;
  LanSyncReceiverConnection? _receiver;
  StreamSubscription<LanSyncSenderEvent>? _senderSubscription;
  StreamSubscription<LanSyncPeer>? _discoverySubscription;
  DiagnosticSpanHandle? _span;
  final Stopwatch _sessionStopwatch = Stopwatch();
  bool _senderTransferRecorded = false;
  int _generation = 0;

  @override
  LanSyncViewState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_disposeResources());
    });
    return const LanSyncViewState();
  }

  Future<void> startSending() async {
    if (state.busy) return;
    final generation = ++_generation;
    await _disposeResources(completeSpan: true);
    if (!_isCurrent(generation)) return;
    state = const LanSyncViewState(role: LanSyncRole.sender, phase: LanSyncPhase.preparing, message: '正在准备插件与书架清单');
    _startSpan(LanSyncRole.sender);
    if (!await _ensureLocalNetwork(generation)) return;
    _recordStage('manifest_prepare_started');
    try {
      final gateway = ref.read(lanSyncGatewayProvider);
      final manifest = await gateway.createManifest();
      if (!_isCurrent(generation)) return;
      final sender = await LanSyncSenderService.start(manifest: manifest, openPlugin: gateway.openPluginArchive);
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

  Future<void> startReceiving() async {
    if (state.busy) return;
    final generation = ++_generation;
    await _disposeResources(completeSpan: true);
    if (!_isCurrent(generation)) return;
    state = const LanSyncViewState(role: LanSyncRole.receiver, phase: LanSyncPhase.discovering, message: '正在查找同一局域网内的发送设备');
    _startSpan(LanSyncRole.receiver);
    if (!await _ensureLocalNetwork(generation)) return;
    _recordStage('discovery_started');
    try {
      final discovery = await LanSyncDiscoveryService.start();
      if (!_isCurrent(generation)) {
        await discovery.close();
        return;
      }
      _discovery = discovery;
      _discoverySubscription = discovery.peers.listen(
        _onPeer,
        onError: (Object error, StackTrace stackTrace) => _onAsyncFailure('discovery', error, stackTrace),
      );
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('discovery', error), errorLocation: 'discovery', error: error, stackTrace: stackTrace);
      }
    }
  }

  void _onPeer(LanSyncPeer peer) {
    if (state.role != LanSyncRole.receiver || state.phase != LanSyncPhase.discovering) {
      return;
    }
    final now = DateTime.now().toUtc();
    final peers = <LanSyncPeer>[
      for (final item in state.peers)
        if (item.expiresAtUtc.isAfter(now) && item.sessionId != peer.sessionId) item,
      peer,
    ]..sort((left, right) => left.label.compareTo(right.label));
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.discovering,
      message: '请选择发送设备',
      peers: List.unmodifiable(peers),
    );
    _recordStage('receiver_connect_started');
  }

  Future<void> connectPeer(LanSyncPeer peer) async {
    await _connectPeers(<LanSyncPeer>[peer]);
  }

  Future<void> connectOffer(LanSyncConnectionOffer offer) async {
    final expiresAt = DateTime.now().toUtc().add(lanSyncSessionLifetime);
    await _connectPeers(<LanSyncPeer>[
      for (final address in offer.addresses)
        LanSyncPeer(sessionId: offer.sessionId, label: '二维码中的发送设备', address: address, port: offer.port, expiresAtUtc: expiresAt),
    ]);
  }

  Future<void> _connectPeers(List<LanSyncPeer> peers) async {
    if (state.role != LanSyncRole.receiver) return;
    final generation = ++_generation;
    try {
      await _discoverySubscription?.cancel();
      await _discovery?.close();
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('discovery_close', error), errorLocation: 'discovery_close', error: error, stackTrace: stackTrace);
      }
      return;
    }
    _discoverySubscription = null;
    _discovery = null;
    if (!_isCurrent(generation)) return;
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.preparing,
      message: peers.length == 1 ? '正在连接发送设备' : '正在并发测试 ${peers.length} 个局域网地址',
    );
    try {
      final receiver = peers.length == 1
          ? await LanSyncReceiverConnection.connect(peers.single)
          : await LanSyncReceiverConnection.connectAny(peers);
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
        peers: <LanSyncPeer>[receiver.peer],
      );
      _recordStage('pairing_ready');
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _fail(_failureCodeFor('connect', error), errorLocation: 'connect', error: error, stackTrace: stackTrace);
      }
    }
  }

  Future<void> connectManual(String value) async {
    final offer = LanSyncConnectionOffer.tryParseManual(value);
    if (offer == null) {
      _fail('lan_sync_manual_address_invalid', keepRole: true);
      return;
    }
    await connectOffer(offer);
  }

  Future<void> confirmReceiverPairing() async {
    final receiver = _receiver;
    if (receiver == null || state.phase != LanSyncPhase.pairing) return;
    final generation = ++_generation;
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.previewing,
      message: '正在读取并检查同步清单',
      pairingCode: state.pairingCode,
      peers: state.peers,
    );
    _recordStage('manifest_preview_started');
    try {
      final manifest = await receiver.confirmAndReadManifest();
      if (!_isCurrent(generation)) return;
      final preview = await ref.read(lanSyncGatewayProvider).previewImport(manifest);
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.previewing,
        message: '确认插件与书架冲突后开始导入',
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
    if (manifest == null || preview == null || !preview.recommendedPluginIds.contains(pluginId)) return;
    final selectedIds = <String>{...preview.selectedPluginIds};
    if (selected) {
      selectedIds.add(pluginId);
    } else {
      selectedIds.remove(pluginId);
    }
    final next = preview.withSelection(pluginIds: selectedIds);
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

  void chooseAllContent(bool selected) {
    final manifest = state.manifest;
    final preview = state.preview;
    if (manifest == null || preview == null) return;
    final next = preview.withSelection(
      pluginIds: selected ? preview.recommendedPluginIds : const <String>{},
      shelfItemIds: selected ? <String>{for (final item in manifest.shelfItems) item.identity} : const <String>{},
    );
    state = _withPreviewSelection(next, manifest);
  }

  LanSyncViewState _withPreviewSelection(LanSyncImportPreview preview, LanSyncManifest manifest) => LanSyncViewState(
    role: state.role,
    phase: state.phase,
    message: state.message,
    connectionOffer: state.connectionOffer,
    pairingCode: state.pairingCode,
    peers: state.peers,
    manifest: manifest,
    preview: preview,
    transferredBytes: state.transferredBytes,
    totalBytes: _selectedPluginBytes(manifest, preview.selectedPluginIds),
    result: state.result,
  );

  Future<void> beginImport() async {
    final receiver = _receiver;
    final manifest = state.manifest;
    final preview = state.preview;
    if (receiver == null || manifest == null || preview == null) return;
    final generation = ++_generation;
    final selectedPluginIds = preview.selectedPluginIds;
    final selectedShelfItemIds = preview.selectedShelfItemIds;
    if (!preview.hasSelection) return;
    final selectedManifest = manifest.selectShelfItems(selectedShelfItemIds);
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
      final gateway = ref.read(lanSyncGatewayProvider);
      await gateway.preparePluginImports(<LanSyncPluginDescriptor>[
        for (final plugin in manifest.plugins)
          if (selectedPluginIds.contains(plugin.id)) plugin,
      ]);
      _recordStage('plugin_transport_started');
      await receiver.receivePlugins(
        pluginIds: selectedPluginIds,
        shelfItemIds: selectedShelfItemIds,
        importPlugin: gateway.importPluginArchive,
        onProgress: (completed, total) {
          if (!_isCurrent(generation)) return;
          state = LanSyncViewState(
            role: LanSyncRole.receiver,
            phase: LanSyncPhase.transferring,
            message: '正在传输插件',
            manifest: manifest,
            preview: preview,
            transferredBytes: completed,
            totalBytes: total,
          );
        },
        onPluginBytesReceived: () {
          if (!_isCurrent(generation)) return;
          state = LanSyncViewState(
            role: LanSyncRole.receiver,
            phase: LanSyncPhase.transferring,
            message: '正在校验并保存插件',
            manifest: manifest,
            preview: preview,
            transferredBytes: state.transferredBytes,
            totalBytes: state.totalBytes,
          );
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
      final pluginResult = await gateway.finishPluginImports();
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
      final result = await gateway.applyImport(
        manifest: selectedManifest,
        conflictChoices: <String, LanSyncConflictChoice>{for (final conflict in preview.conflicts) conflict.identity: conflict.choice},
        availablePluginIds: pluginResult.availablePluginIds,
        pluginResult: pluginResult,
      );
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.completed,
        message: '局域网同步完成',
        manifest: manifest,
        result: result,
        transferredBytes: state.transferredBytes,
        totalBytes: state.totalBytes,
      );
      _recordStage('library_apply_completed');
      _completeSpan('success', errorCode: pluginResult.failureCode);
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
      case LanSyncSenderFailed(:final code, :final error, :final stackTrace):
        _fail(code, errorLocation: 'sender_transport', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> cancel() async {
    _generation++;
    _recordStage('cancel_requested');
    _completeSpan('cancelled');
    await _cancelPluginImportsSafely();
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
    unawaited(_cancelPluginImportsSafely());
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

  Future<void> _cancelPluginImportsSafely() async {
    try {
      await ref.read(lanSyncGatewayProvider).cancelPluginImports();
    } on Object {
      // Cleanup must not turn a cancelled or failed sync into a root-isolate error.
    }
  }

  Future<void> _disposeResources({bool completeSpan = false}) async {
    if (completeSpan) _completeSpan('cancelled');
    final senderSubscription = _senderSubscription;
    _senderSubscription = null;
    try {
      await senderSubscription?.cancel();
    } on Object {
      // 释放阶段不能覆盖同步会话本身的结果。
    }

    final discoverySubscription = _discoverySubscription;
    _discoverySubscription = null;
    try {
      await discoverySubscription?.cancel();
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

    final discovery = _discovery;
    _discovery = null;
    try {
      await discovery?.close();
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
  }

  bool _isCurrent(int generation) => generation == _generation;
}

/// Converts LAN failure codes into user-facing copy.
String lanSyncFailureMessage(String code) => switch (code) {
  'lan_sync_wifi_required' => '手机未连接 Wi-Fi，已停止局域网同步和广播',
  'lan_sync_local_network_unavailable' => '未检测到可用局域网，请检查 Wi-Fi 或网线连接',
  'lan_sync_manual_address_invalid' => '连接地址格式不正确',
  'lan_sync_address_not_private' => '只能连接同一私有局域网内的设备',
  'lan_sync_discovery_failed' => '无法查找局域网设备，请尝试手动输入地址',
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
