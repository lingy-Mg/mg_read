/// Durable video history independent of shelf membership. Device/session
/// sequence orders a branch; generation plus CAS protects newer local viewing.
/// Only source metadata is serialized: resolved stream URLs, cookies, local
/// media paths, and transport credentials are deliberately absent.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as video_history_crypto;

final class VideoHistoryCheckpoint {
  const VideoHistoryCheckpoint({
    required this.pluginId,
    required this.contentId,
    required this.pluginVersion,
    required this.title,
    required this.groupId,
    required this.episodeId,
    required this.position,
    required this.duration,
    required this.originDeviceId,
    required this.playbackSessionId,
    required this.sequence,
    required this.localGeneration,
    required this.updatedAtUtc,
    this.controllerDeviceId,
  });
  final String pluginId, contentId, pluginVersion, title, groupId, episodeId, originDeviceId, playbackSessionId;
  final Duration position, duration;
  final int sequence, localGeneration;
  final DateTime updatedAtUtc;
  final String? controllerDeviceId;
  String get sourceKey => videoHistorySourceKey(pluginId, contentId);
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'pluginId': pluginId,
      'contentId': contentId,
      'pluginVersion': pluginVersion,
      'title': title,
      'groupId': groupId,
      'episodeId': episodeId,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'originDeviceId': originDeviceId,
      'playbackSessionId': playbackSessionId,
      'sequence': sequence,
      'localGeneration': localGeneration,
      'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
      if (controllerDeviceId != null) 'controllerDeviceId': controllerDeviceId,
    };
    VideoHistoryCheckpoint.fromJson(json);
    return json;
  }

  factory VideoHistoryCheckpoint.fromJson(Map<String, Object?> json) {
    const keys = <String>{
      'pluginId',
      'contentId',
      'pluginVersion',
      'title',
      'groupId',
      'episodeId',
      'originDeviceId',
      'playbackSessionId',
      'positionMs',
      'durationMs',
      'sequence',
      'localGeneration',
      'updatedAtUtc',
    };
    if (json.keys.any((key) => !keys.contains(key) && key != 'controllerDeviceId') || keys.any((key) => !json.containsKey(key))) {
      throw const FormatException('video_history_schema');
    }
    final controller = json['controllerDeviceId'];
    if (controller != null && (controller is! String || controller.isEmpty || controller.length > 128)) {
      throw const FormatException('video_history_controller');
    }
    const limits = <String, int>{
      'pluginId': 128,
      'contentId': 2048,
      'pluginVersion': 128,
      'title': 512,
      'groupId': 2048,
      'episodeId': 2048,
      'originDeviceId': 128,
      'playbackSessionId': 128,
    };
    for (final entry in limits.entries) {
      final value = json[entry.key];
      if (value is! String || value.isEmpty || value.length > entry.value) {
        throw FormatException('video_history_${entry.key}');
      }
    }
    for (final key in <String>['pluginId', 'contentId', 'groupId', 'episodeId']) {
      final value = json[key]! as String;
      if (RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\|file:|/(?:Users|home|storage|sdcard|data)/)', caseSensitive: false).hasMatch(value)) {
        throw const FormatException('video_history_local_path');
      }
    }
    final contentId = json['contentId']! as String;
    if (RegExp(r'[?&](?:access_token|auth|authorization|cookie|key|session|token)=', caseSensitive: false).hasMatch(contentId)) {
      throw const FormatException('video_history_sensitive_content_id');
    }
    for (final key in ['positionMs', 'durationMs', 'sequence', 'localGeneration']) {
      final value = json[key];
      if (value is! int || value < 0 || value > 9007199254740991) throw const FormatException('video_history_number');
    }
    final rawDate = json['updatedAtUtc'];
    if (rawDate is! String) throw const FormatException('video_history_date');
    final date = DateTime.tryParse(rawDate);
    if (date == null || !date.isUtc) throw const FormatException('video_history_date');
    return VideoHistoryCheckpoint(
      pluginId: json['pluginId'] as String,
      contentId: json['contentId'] as String,
      pluginVersion: json['pluginVersion'] as String,
      title: json['title'] as String,
      groupId: json['groupId'] as String,
      episodeId: json['episodeId'] as String,
      position: Duration(milliseconds: json['positionMs'] as int),
      duration: Duration(milliseconds: json['durationMs'] as int),
      originDeviceId: json['originDeviceId'] as String,
      playbackSessionId: json['playbackSessionId'] as String,
      sequence: json['sequence'] as int,
      localGeneration: json['localGeneration'] as int,
      updatedAtUtc: date,
      controllerDeviceId: controller as String?,
    );
  }
}

/// Collision-free key accepted by ContentLibrary's video history read API.
String videoHistorySourceKey(String pluginId, String contentId) => jsonEncode(<String>[pluginId, contentId]);

/// Stable bounded persistence ID derived from a collision-free source identity.
String videoHistoryRecordId(String sourceKey, {String? origin}) {
  final identity = origin == null ? 'resume\u0000$sourceKey' : 'branch\u0000$sourceKey\u0000$origin';
  final digest = video_history_crypto.sha256.convert(utf8.encode(identity)).toString();
  return 'video-history:$digest';
}

final class VideoHistoryEntry {
  const VideoHistoryEntry({required this.checkpoint, required this.revision});
  final VideoHistoryCheckpoint checkpoint;
  final int revision;
}

enum VideoHistorySaveStatus { committed, duplicate, conflict }

final class VideoHistorySaveResult {
  const VideoHistorySaveResult(this.status, this.revision);
  final VideoHistorySaveStatus status;
  final int revision;
}
