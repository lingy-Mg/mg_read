/// Typed, metadata-only phone/TV identities and state. No resolved media URL,
/// cookie, local path, or transport secret belongs to these public projections.
library;

import 'package:flutter/foundation.dart';
import 'package:mg_read/core/content_library/content_library.dart' show videoHistorySourceKey;

@immutable
final class CompanionContentRef {
  const CompanionContentRef({
    required this.pluginId,
    required this.contentId,
    required this.title,
    required this.groupId,
    required this.episodeId,
    this.pluginVersion = 'unknown',
    this.positionMs = 0,
    this.useTvProgress = false,
  });
  final String pluginId, contentId, title, groupId, episodeId, pluginVersion;
  final int positionMs;
  final bool useTvProgress;
  String get identity => videoHistorySourceKey(pluginId, contentId);
  Map<String, Object?> toJson() => {
    'kind': 'source',
    'pluginId': pluginId,
    'contentId': contentId,
    'title': title,
    'groupId': groupId,
    'episodeId': episodeId,
    'pluginVersion': pluginVersion,
    'positionMs': positionMs,
    'useTvProgress': useTvProgress,
  };
  factory CompanionContentRef.fromJson(Map<String, Object?> json) {
    if (json['kind'] != 'source') throw const CompanionFailure('local_content_unsupported');
    final position = json['positionMs'];
    if (position is! int || position < 0 || position > 31536000000) {
      throw const CompanionFailure('invalid_position');
    }
    return CompanionContentRef(
      pluginId: companionText(json, 'pluginId'),
      contentId: companionText(json, 'contentId'),
      title: companionText(json, 'title', max: 512),
      groupId: companionText(json, 'groupId'),
      episodeId: companionText(json, 'episodeId'),
      pluginVersion: companionText(json, 'pluginVersion', max: 128),
      positionMs: position,
      useTvProgress: json['useTvProgress'] == true,
    );
  }
}

@immutable
final class CompanionEndpoint {
  const CompanionEndpoint({
    required this.deviceId,
    required this.label,
    required this.address,
    required this.port,
    required this.expiresAt,
    required this.receiving,
  });
  final String deviceId, label, address;
  final int port;
  final DateTime expiresAt;
  final bool receiving;
  Uri get uri => Uri(scheme: 'ws', host: address, port: port, path: '/companion/v1/ws');
}

enum CompanionConnectionStatus { disconnected, connecting, connected, reconnecting, unauthorized }

/// A touch/typing gesture is tied to the target and control generation at its
/// start. Debounced work cannot silently reacquire control after a local edit.
final class CompanionInteraction {
  const CompanionInteraction(this.deviceId, this.hostEpoch, this.controlGeneration, this.playbackGeneration);
  final String deviceId, hostEpoch;
  final int controlGeneration, playbackGeneration;
}

@immutable
final class CompanionPlaybackSnapshot {
  const CompanionPlaybackSnapshot({
    required this.sequence,
    required this.hostEpoch,
    required this.serverMs,
    required this.controlGeneration,
    required this.playbackGeneration,
    this.controllerId,
    this.content,
    this.playbackSessionId,
    this.status = 'idle',
    this.playing = false,
    this.buffering = false,
    this.firstFrame = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedMs = 0,
    this.rate = 1,
    this.volume = 100,
    this.hasPrevious = false,
    this.hasNext = false,
    this.failureCode,
    this.saveFailure = false,
    this.systemVolume,
    this.canSystemVolume = false,
    this.groups = const [],
    this.receiving = true,
  });
  final int sequence, serverMs, controlGeneration, playbackGeneration;
  final String hostEpoch, status;
  final String? controllerId, playbackSessionId, failureCode;
  final CompanionContentRef? content;
  final bool playing, buffering, firstFrame, hasPrevious, hasNext, saveFailure, canSystemVolume, receiving;
  final int positionMs, durationMs, bufferedMs;
  final double rate, volume;
  final double? systemVolume;
  final List<CompanionEpisodeGroup> groups;
  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'hostEpoch': hostEpoch,
    'serverMs': serverMs,
    'controlGeneration': controlGeneration,
    'playbackGeneration': playbackGeneration,
    'controllerId': controllerId,
    'content': content?.toJson(),
    'playbackSessionId': playbackSessionId,
    'status': status,
    'playing': playing,
    'buffering': buffering,
    'firstFrame': firstFrame,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'bufferedMs': bufferedMs,
    'rate': rate,
    'volume': volume,
    'hasPrevious': hasPrevious,
    'hasNext': hasNext,
    'failureCode': failureCode,
    'saveFailure': saveFailure,
    'systemVolume': systemVolume,
    'canSystemVolume': canSystemVolume,
    'receiving': receiving,
    'groups': [for (final group in groups) group.toJson()],
  };
  factory CompanionPlaybackSnapshot.fromJson(Map<String, Object?> json) => CompanionPlaybackSnapshot(
    sequence: companionInt(json, 'sequence'),
    hostEpoch: companionText(json, 'hostEpoch', max: 128),
    serverMs: companionInt(json, 'serverMs'),
    controlGeneration: companionInt(json, 'controlGeneration'),
    playbackGeneration: companionInt(json, 'playbackGeneration'),
    controllerId: json['controllerId'] as String?,
    content: json['content'] == null ? null : CompanionContentRef.fromJson(companionMap(json['content'])),
    playbackSessionId: json['playbackSessionId'] as String?,
    status: companionText(json, 'status', max: 64),
    playing: json['playing'] == true,
    buffering: json['buffering'] == true,
    firstFrame: json['firstFrame'] == true,
    positionMs: companionInt(json, 'positionMs'),
    durationMs: companionInt(json, 'durationMs'),
    bufferedMs: companionInt(json, 'bufferedMs'),
    rate: (json['rate'] as num).toDouble(),
    volume: (json['volume'] as num).toDouble(),
    hasPrevious: json['hasPrevious'] == true,
    hasNext: json['hasNext'] == true,
    failureCode: json['failureCode'] as String?,
    saveFailure: json['saveFailure'] == true,
    systemVolume: (json['systemVolume'] as num?)?.toDouble(),
    canSystemVolume: json['canSystemVolume'] == true,
    receiving: json['receiving'] == true,
    groups: [for (final group in (json['groups'] as List).take(50)) CompanionEpisodeGroup.fromJson(companionMap(group))],
  );
}

@immutable
final class CompanionEpisodeGroup {
  const CompanionEpisodeGroup({required this.id, required this.title, required this.deferred, this.episodes = const []});
  final String id, title;
  final bool deferred;
  final List<CompanionEpisode> episodes;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'deferred': deferred,
    'episodes': [for (final episode in episodes) episode.toJson()],
  };
  factory CompanionEpisodeGroup.fromJson(Map<String, Object?> json) => CompanionEpisodeGroup(
    id: companionText(json, 'id'),
    title: companionText(json, 'title', max: 512),
    deferred: json['deferred'] == true,
    episodes: [for (final episode in (json['episodes'] as List).take(50)) CompanionEpisode.fromJson(companionMap(episode))],
  );
}

@immutable
final class CompanionEpisode {
  const CompanionEpisode(this.id, this.title);
  final String id, title;
  Map<String, Object?> toJson() => {'id': id, 'title': title};
  factory CompanionEpisode.fromJson(Map<String, Object?> json) =>
      CompanionEpisode(companionText(json, 'id'), companionText(json, 'title', max: 512));
}

final class CompanionFailure implements Exception {
  const CompanionFailure(this.code);
  final String code;
  @override
  String toString() => code;
}

Map<String, Object?> companionMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) throw const CompanionFailure('invalid_message');
  return Map<String, Object?>.from(value);
}

String companionText(Map<String, Object?> value, String key, {int max = 2048}) {
  final text = value[key];
  if (text is! String || text.isEmpty || text.length > max) throw const CompanionFailure('invalid_message');
  return text;
}

int companionInt(Map<String, Object?> value, String key) {
  final number = value[key];
  if (number is! int || number < 0 || number > 9007199254740991) throw const CompanionFailure('invalid_message');
  return number;
}
