/// 局域网同步二维码扫描页。
///
/// 职责：
/// - 管理相机扫描器生命周期，并识别 MgRead 的配对、数据同步和 App 传输二维码。
/// - 仅向上层路由返回已验证的二维码载荷；具体业务路由由页面控制器决定。
///
/// 注意：
/// - 扫描器必须在页面释放时停止和释放。
/// - 不直接启动同步或保存二维码内容。
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';

enum LanSyncQrScannerPurpose {
  auto,
  sync,
  pairing,
  appTransfer;

  bool accepts(String payload) => switch (this) {
    LanSyncQrScannerPurpose.auto =>
      LanPairingQrPayload.decode(payload) != null ||
          LanSyncQrPayload.decode(payload) != null ||
          AppTransferQrPayload.decode(payload) != null,
    LanSyncQrScannerPurpose.sync => LanSyncQrPayload.decode(payload) != null,
    LanSyncQrScannerPurpose.pairing => LanPairingQrPayload.decode(payload) != null,
    LanSyncQrScannerPurpose.appTransfer => AppTransferQrPayload.decode(payload) != null,
  };

  String get title => switch (this) {
    LanSyncQrScannerPurpose.auto => '扫码',
    LanSyncQrScannerPurpose.sync => '扫描同步二维码',
    LanSyncQrScannerPurpose.pairing => '扫码配对设备',
    LanSyncQrScannerPurpose.appTransfer => '扫描 App 二维码',
  };

  String get scanHint => switch (this) {
    LanSyncQrScannerPurpose.auto => '扫描配对、数据同步或 App 传输二维码',
    LanSyncQrScannerPurpose.sync => '将发送端二维码放入取景框',
    LanSyncQrScannerPurpose.pairing => '将另一台设备的配对二维码放入取景框',
    LanSyncQrScannerPurpose.appTransfer => '将发送 App 的二维码放入取景框',
  };

  String get invalidMessage => switch (this) {
    LanSyncQrScannerPurpose.auto => '这不是有效的 MgRead 局域网二维码',
    LanSyncQrScannerPurpose.sync => '这不是 MgRead 局域网同步二维码',
    LanSyncQrScannerPurpose.pairing => '这不是 MgRead 设备配对二维码',
    LanSyncQrScannerPurpose.appTransfer => '这不是 MgRead App 传输二维码',
  };
}

class LanSyncQrScannerPage extends StatefulWidget {
  const LanSyncQrScannerPage({super.key, this.purpose = LanSyncQrScannerPurpose.auto});

  final LanSyncQrScannerPurpose purpose;

  @override
  State<LanSyncQrScannerPage> createState() => _LanSyncQrScannerPageState();
}

class _LanSyncQrScannerPageState extends State<LanSyncQrScannerPage> with WidgetsBindingObserver {
  late final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  bool _isClosing = false;
  bool _isStarting = false;
  bool _shouldRun = true;
  bool _cameraUnavailable = false;
  late String _message;

  @override
  void initState() {
    super.initState();
    _message = widget.purpose.scanHint;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startScanner());
    });
  }

  @override
  void dispose() {
    _isClosing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeControllerSafely());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _shouldRun = true;
        unawaited(_startScanner());
      case AppLifecycleState.inactive || AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _shouldRun = false;
        unawaited(_stopScanner());
    }
  }

  Future<void> _startScanner() async {
    if (_isClosing || !_shouldRun || _isStarting || _cameraUnavailable) return;
    _isStarting = true;
    try {
      await _controller.start();
      if (_isClosing || !_shouldRun) await _stopScanner();
    } on Object {
      if (mounted) {
        setState(() {
          _cameraUnavailable = true;
          _message = '无法使用相机，请检查相机权限后重试';
        });
      }
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _stopScanner() async {
    try {
      await _controller.stop();
    } on Object {
      // A lifecycle transition can race with CameraX shutdown on Android.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final payload = barcode.rawValue;
      if (payload == null) continue;
      if (!widget.purpose.accepts(payload)) {
        if (mounted) setState(() => _message = widget.purpose.invalidMessage);
        continue;
      }
      _handled = true;
      unawaited(_finish(payload));
      return;
    }
  }

  Future<void> _finish(String payload) async {
    _isClosing = true;
    await _stopScanner();
    if (mounted) Navigator.of(context).pop(payload);
  }

  Future<void> _disposeControllerSafely() async {
    await _stopScanner();
    try {
      await _controller.dispose();
    } on Object {
      // Camera resources are best-effort during widget teardown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.purpose.title),
        leading: IconButton(
          key: const Key('lan-sync-scanner-close'),
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭扫码',
        ),
      ),
      body: Semantics(
        label: switch (widget.purpose) {
          LanSyncQrScannerPurpose.auto => 'MgRead 局域网二维码扫描器',
          LanSyncQrScannerPurpose.pairing => '设备配对二维码扫描器',
          LanSyncQrScannerPurpose.appTransfer => 'App 传输二维码扫描器',
          LanSyncQrScannerPurpose.sync => '局域网同步二维码扫描器',
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_cameraUnavailable)
              ColoredBox(
                color: colorScheme.surface,
                child: const Center(child: Text('无法使用相机，请检查相机权限')),
              )
            else
              MobileScanner(
                key: const Key('lan-sync-qr-scanner'),
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => ColoredBox(
                  color: colorScheme.surface,
                  child: const Center(child: Text('无法使用相机，请检查相机权限')),
                ),
              ),
            Center(
              child: IgnorePointer(
                child: Container(
                  width: 248,
                  height: 248,
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.primary, width: 3),
                    borderRadius: AppRadii.control,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                minimum: const EdgeInsets.all(AppSpacing.regular),
                child: Card(
                  color: colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.regular),
                    child: Text(_message, textAlign: TextAlign.center),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
