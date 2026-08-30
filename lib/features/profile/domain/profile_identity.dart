/// 仅用于本机展示的个人资料。
///
/// 职责：
/// - 表达资料卡可编辑的昵称与个性签名。
/// - 提供与应用设置 JSON 值之间的有界转换。
///
/// 注意：
/// - 这不是账号身份，不包含用户 ID、登录态或云端字段。
/// - 字段上限同时用于持久化校验和编辑页输入约束。
library;

import 'package:flutter/foundation.dart';

@immutable
final class ProfileIdentity {
  const ProfileIdentity({required this.displayName, required this.motto});

  static const int displayNameMaxLength = 20;
  static const int mottoMaxLength = 50;

  static const ProfileIdentity defaults = ProfileIdentity(displayName: '书海行者', motto: '书山有路勤为径，阅读点亮生活。');

  final String displayName;
  final String motto;

  factory ProfileIdentity.fromSettingValue(Map<String, Object?> value) {
    return ProfileIdentity(displayName: value['displayName'] as String, motto: value['motto'] as String);
  }

  Map<String, Object?> toSettingValue() => <String, Object?>{'displayName': displayName, 'motto': motto};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProfileIdentity && other.displayName == displayName && other.motto == motto;

  @override
  int get hashCode => Object.hash(displayName, motto);
}
