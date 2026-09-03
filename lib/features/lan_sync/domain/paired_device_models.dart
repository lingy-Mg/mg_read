/// 持久配对设备、同步授权与设备身份模型。
///
/// 职责：
/// - 以稳定设备 ID 表示长期信任关系，IP 只属于瞬时发现结果。
/// - 保存每台设备允许的同步方向、内容范围和自动同步策略。
///
/// 注意：
/// - 配对密钥不进入本模型、普通 metadata、日志或诊断。
/// - 删除同步默认不传播；配对授权只覆盖书架/进度和数据源插件。
library;

import 'package:flutter/foundation.dart';

enum PairedDevicePlatform {
  android,
  windows,
  macos,
  unknown;

  bool get isDesktop => this == PairedDevicePlatform.windows || this == PairedDevicePlatform.macos;
}

enum PairedSyncMode { bidirectional, receiveOnly, sendOnly }

/// 由本机发起的单次同步操作；持久设备策略仍会限制实际可发送和可接收的内容。
enum PairedSyncOperation {
  bidirectional,
  pull,
  push;

  bool get receives => this != PairedSyncOperation.push;
  bool get sends => this != PairedSyncOperation.pull;

  PairedSyncOperation get reversed => switch (this) {
    PairedSyncOperation.bidirectional => PairedSyncOperation.bidirectional,
    PairedSyncOperation.pull => PairedSyncOperation.push,
    PairedSyncOperation.push => PairedSyncOperation.pull,
  };
}

enum PairedSyncResultState { success, partial, failed, cancelled }

@immutable
final class LocalDeviceIdentity {
  const LocalDeviceIdentity({required this.deviceId, required this.label});

  final String deviceId;
  final String label;
}

@immutable
final class PairedDevice {
  const PairedDevice({
    required this.autoSync,
    required this.createdAtUtc,
    required this.deviceId,
    required this.label,
    required this.mode,
    required this.platform,
    required this.syncBookshelf,
    required this.syncPlugins,
    this.lastSeenAtUtc,
    this.lastSyncAtUtc,
    this.lastSyncResult,
  });

  final bool autoSync;
  final DateTime createdAtUtc;
  final String deviceId;
  final String label;
  final PairedSyncMode mode;
  final PairedDevicePlatform platform;
  final bool syncBookshelf;
  final bool syncPlugins;
  final DateTime? lastSeenAtUtc;
  final DateTime? lastSyncAtUtc;
  final PairedSyncResultState? lastSyncResult;

  bool get canReceive => mode != PairedSyncMode.sendOnly;
  bool get canSend => mode != PairedSyncMode.receiveOnly;

  PairedDevice copyWith({
    bool? autoSync,
    String? label,
    PairedSyncMode? mode,
    PairedDevicePlatform? platform,
    bool? syncBookshelf,
    bool? syncPlugins,
    DateTime? lastSeenAtUtc,
    DateTime? lastSyncAtUtc,
    PairedSyncResultState? lastSyncResult,
  }) => PairedDevice(
    autoSync: autoSync ?? this.autoSync,
    createdAtUtc: createdAtUtc,
    deviceId: deviceId,
    label: label ?? this.label,
    mode: mode ?? this.mode,
    platform: platform ?? this.platform,
    syncBookshelf: syncBookshelf ?? this.syncBookshelf,
    syncPlugins: syncPlugins ?? this.syncPlugins,
    lastSeenAtUtc: lastSeenAtUtc ?? this.lastSeenAtUtc,
    lastSyncAtUtc: lastSyncAtUtc ?? this.lastSyncAtUtc,
    lastSyncResult: lastSyncResult ?? this.lastSyncResult,
  );
}

bool isValidPairedDeviceId(String value) => value.length >= 16 && value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
