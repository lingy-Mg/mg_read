/// 局域网数据同步、App 传输和设备配对共用的二维码视觉。
///
/// 只渲染调用方提供的载荷，不持有会话、密钥或 IO。主题色仅用于边框和深色码点；
/// 扫码区域始终使用不透明白底，四周按实际矩阵保留至少四个模块的静区，避免夜间反色。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';

class LanSyncQrCode extends StatelessWidget {
  const LanSyncQrCode({required this.data, required this.semanticsLabel, required this.qrKey, super.key});

  final String data;
  final String semanticsLabel;
  final Key qrKey;

  @override
  Widget build(BuildContext context) {
    final accent = AppThemeTokens.of(context).accent;
    final ink = Color.lerp(Colors.black, accent, 0.34)!;
    final qr = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
    return Semantics(
      container: true,
      image: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(244.0, constraints.maxWidth);
            final imageSize = size - AppSpacing.compact * 2;
            // 与绘图库的半像素步长对齐，避免矩阵取整后挤占静区；圆角另留余量。
            final moduleSize = ((imageSize - AppSpacing.compact) / (qr.moduleCount + 8) * 2).floorToDouble() / 2;
            final quietZone = (imageSize - moduleSize * qr.moduleCount) / 2;
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(accent.withValues(alpha: 0.12), Colors.white),
                borderRadius: AppRadii.card,
                border: Border.all(color: Color.alphaBlend(accent.withValues(alpha: 0.3), Colors.white)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.compact),
                child: ClipRRect(
                  borderRadius: AppRadii.surface,
                  child: QrImageView.withQr(
                    key: qrKey,
                    qr: qr,
                    size: imageSize,
                    padding: EdgeInsets.all(quietZone),
                    backgroundColor: Colors.white,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: ink),
                    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: ink),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
