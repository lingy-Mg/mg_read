import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';

final lanSyncControllerProvider =
    NotifierProvider.autoDispose<LanSyncController, LanSyncViewState>(
      LanSyncController.new,
    );

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

  double? get progress =>
      totalBytes <= 0 ? null : (transferredBytes / totalBytes).clamp(0.0, 1.0);
}

final class LanSyncController extends Notifier<LanSyncViewState> {
  LanSyncSenderService? _sender;
  LanSyncDiscoveryService? _discovery;
  LanSyncReceiverConnection? _receiver;
  StreamSubscription<LanSyncSenderEvent>? _senderSubscription;
  StreamSubscription<LanSyncPeer>? _discoverySubscription;
  DiagnosticSpanHandle? _span;
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
    state = const LanSyncViewState(
      role: LanSyncRole.sender,
      phase: LanSyncPhase.preparing,
      message: '正在准备插件与书架清单',
    );
    _startSpan(LanSyncRole.sender);
    try {
      final gateway = ref.read(lanSyncGatewayProvider);
      final manifest = await gateway.createManifest();
      if (!_isCurrent(generation)) return;
      final sender = await LanSyncSenderService.start(
        manifest: manifest,
        openPlugin: gateway.openPluginArchive,
      );
      if (!_isCurrent(generation)) {
        await sender.close();
        return;
      }
      _sender = sender;
      _senderSubscription = sender.events.listen(_onSenderEvent);
      final connectionOffer = sender.addresses.isEmpty
          ? null
          : LanSyncConnectionOffer(
              sessionId: sender.sessionId,
              port: sender.port,
              addresses: sender.addresses,
            );
      state = LanSyncViewState(
        role: LanSyncRole.sender,
        phase: LanSyncPhase.waitingForPeer,
        message: '等待接收设备连接',
        connectionOffer: connectionOffer,
        manifest: manifest,
        totalBytes: manifest.plugins
            .where((item) => item.transferable)
            .fold<int>(0, (sum, item) => sum + item.bytes),
      );
    } on Object {
      if (_isCurrent(generation)) _fail('lan_sync_prepare_failed');
    }
  }

  Future<void> startReceiving() async {
    if (state.busy) return;
    final generation = ++_generation;
    await _disposeResources(completeSpan: true);
    if (!_isCurrent(generation)) return;
    state = const LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.discovering,
      message: '正在查找同一局域网内的发送设备',
    );
    _startSpan(LanSyncRole.receiver);
    try {
      final discovery = await LanSyncDiscoveryService.start();
      if (!_isCurrent(generation)) {
        await discovery.close();
        return;
      }
      _discovery = discovery;
      _discoverySubscription = discovery.peers.listen(_onPeer);
    } on Object {
      if (_isCurrent(generation)) _fail('lan_sync_discovery_failed');
    }
  }

  void _onPeer(LanSyncPeer peer) {
    if (state.role != LanSyncRole.receiver ||
        state.phase != LanSyncPhase.discovering) {
      return;
    }
    final now = DateTime.now().toUtc();
    final peers = <LanSyncPeer>[
      for (final item in state.peers)
        if (item.expiresAtUtc.isAfter(now) && item.sessionId != peer.sessionId)
          item,
      peer,
    ]..sort((left, right) => left.label.compareTo(right.label));
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.discovering,
      message: '请选择发送设备',
      peers: List.unmodifiable(peers),
    );
  }

  Future<void> connectPeer(LanSyncPeer peer) async {
    await _connectPeers(<LanSyncPeer>[peer]);
  }

  Future<void> connectOffer(LanSyncConnectionOffer offer) async {
    final expiresAt = DateTime.now().toUtc().add(lanSyncSessionLifetime);
    await _connectPeers(<LanSyncPeer>[
      for (final address in offer.addresses)
        LanSyncPeer(
          sessionId: offer.sessionId,
          label: '二维码中的发送设备',
          address: address,
          port: offer.port,
          expiresAtUtc: expiresAt,
        ),
    ]);
  }

  Future<void> _connectPeers(List<LanSyncPeer> peers) async {
    if (state.role != LanSyncRole.receiver) return;
    final generation = ++_generation;
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    await _discovery?.close();
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
    } on Object {
      if (_isCurrent(generation)) _fail('lan_sync_connect_failed');
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

  void confirmSenderPairing() => _sender?.confirmPairing();

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
    try {
      final manifest = await receiver.confirmAndReadManifest();
      if (!_isCurrent(generation)) return;
      final preview = await ref
          .read(lanSyncGatewayProvider)
          .previewImport(manifest);
      if (!_isCurrent(generation)) return;
      state = LanSyncViewState(
        role: LanSyncRole.receiver,
        phase: LanSyncPhase.previewing,
        message: '确认插件与书架冲突后开始导入',
        manifest: manifest,
        preview: preview,
        totalBytes: preview.recommendedPluginIds.fold<int>(
          0,
          (sum, id) =>
              sum + manifest.plugins.firstWhere((item) => item.id == id).bytes,
        ),
      );
    } on Object {
      if (_isCurrent(generation)) _fail('lan_sync_preview_failed');
    }
  }

  void chooseConflict(String identity, LanSyncConflictChoice choice) {
    final preview = state.preview;
    if (preview == null) return;
    final next = LanSyncImportPreview(
      newItemCount: preview.newItemCount,
      conflicts: List.unmodifiable(<LanSyncBookConflict>[
        for (final conflict in preview.conflicts)
          conflict.identity == identity
              ? conflict.withChoice(choice)
              : conflict,
      ]),
      blockedItemCount: preview.blockedItemCount,
      pluginPlans: preview.pluginPlans,
    );
    state = LanSyncViewState(
      role: state.role,
      phase: state.phase,
      message: state.message,
      manifest: state.manifest,
      preview: next,
      totalBytes: state.totalBytes,
    );
  }

  Future<void> beginImport() async {
    final receiver = _receiver;
    final manifest = state.manifest;
    final preview = state.preview;
    if (receiver == null || manifest == null || preview == null) return;
    final generation = ++_generation;
    final selectedPluginIds = preview.recommendedPluginIds;
    state = LanSyncViewState(
      role: LanSyncRole.receiver,
      phase: LanSyncPhase.transferring,
      message: selectedPluginIds.isEmpty ? '正在应用书架数据' : '正在传输插件',
      manifest: manifest,
      preview: preview,
      totalBytes: state.totalBytes,
    );
    try {
      final gateway = ref.read(lanSyncGatewayProvider);
      await gateway.preparePluginImports(<LanSyncPluginDescriptor>[
        for (final plugin in manifest.plugins)
          if (selectedPluginIds.contains(plugin.id)) plugin,
      ]);
      await receiver.receivePlugins(
        pluginIds: selectedPluginIds,
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
      );
      if (!_isCurrent(generation)) return;
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
      final result = await gateway.applyImport(
        manifest: manifest,
        conflictChoices: <String, LanSyncConflictChoice>{
          for (final conflict in preview.conflicts)
            conflict.identity: conflict.choice,
        },
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
      _completeSpan('success');
      await _disposeResources();
    } on Object {
      if (_isCurrent(generation)) _fail('lan_sync_import_failed');
    }
  }

  void _onSenderEvent(LanSyncSenderEvent event) {
    if (state.role != LanSyncRole.sender ||
        state.phase == LanSyncPhase.cancelled ||
        state.phase == LanSyncPhase.failed) {
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
      case LanSyncSenderDone():
        state = LanSyncViewState(
          role: LanSyncRole.sender,
          phase: LanSyncPhase.completed,
          message: '发送完成',
          manifest: state.manifest,
          transferredBytes: state.transferredBytes,
          totalBytes: state.totalBytes,
        );
        _completeSpan('success');
      case LanSyncSenderFailed(:final code):
        _fail(code);
    }
  }

  Future<void> cancel() async {
    _generation++;
    _completeSpan('cancelled');
    await ref.read(lanSyncGatewayProvider).cancelPluginImports();
    await _disposeResources();
    state = const LanSyncViewState(
      phase: LanSyncPhase.cancelled,
      message: '同步已取消',
    );
  }

  void reset() {
    _generation++;
    unawaited(_disposeResources(completeSpan: true));
    state = const LanSyncViewState();
  }

  void _fail(String code, {bool keepRole = false}) {
    _generation++;
    _completeSpan('error', errorCode: code);
    final role = keepRole ? state.role : null;
    unawaited(ref.read(lanSyncGatewayProvider).cancelPluginImports());
    unawaited(_disposeResources());
    state = LanSyncViewState(
      role: role,
      phase: LanSyncPhase.failed,
      message: _messageForError(code),
      errorCode: code,
    );
  }

  void _startSpan(LanSyncRole role) {
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

  void _completeSpan(String resultState, {String? errorCode}) {
    final span = _span;
    if (span == null) return;
    _span = null;
    final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
      'stage': DiagnosticValue.string('terminal'),
      'resultState': DiagnosticValue.string(resultState),
      if (state.manifest case final manifest?) ...<String, DiagnosticValue>{
        'pluginCount': DiagnosticValue.int64(manifest.plugins.length),
        'itemCount': DiagnosticValue.int64(manifest.shelfItems.length),
      },
      'bytes': DiagnosticValue.int64(state.transferredBytes),
      if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
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
    }
  }

  Future<void> _disposeResources({bool completeSpan = false}) async {
    if (completeSpan) _completeSpan('cancelled');
    await _senderSubscription?.cancel();
    _senderSubscription = null;
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    await _sender?.close();
    _sender = null;
    await _discovery?.close();
    _discovery = null;
    await _receiver?.close();
    _receiver = null;
  }

  bool _isCurrent(int generation) => generation == _generation;
}

String _messageForError(String code) => switch (code) {
  'lan_sync_manual_address_invalid' => '连接地址格式不正确',
  'lan_sync_address_not_private' => '只能连接同一私有局域网内的设备',
  'lan_sync_discovery_failed' => '无法查找局域网设备，请尝试手动输入地址',
  'lan_sync_connect_failed' => '连接失败，请确认两台设备在同一网络',
  'lan_sync_preview_failed' => '同步清单无法读取或版本不兼容',
  'lan_sync_import_failed' => '导入未完成，本机原有书架不会被删除',
  'lan_sync_timeout' => '等待确认超时，请重新开始同步',
  _ => '局域网同步失败，请重试',
};
