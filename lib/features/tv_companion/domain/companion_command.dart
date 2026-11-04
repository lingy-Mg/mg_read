/// Wire types shared by the TV companion transport and its command engine.
///
/// This file has no Flutter or transport dependencies. It owns strict JSON
/// decoding and protocol bounds; routing, authorization, and execution belong
/// to the application layer.
library;

import 'dart:convert';

enum CompanionCommandType {
  acquireControl,
  releaseControl,
  play,
  pause,
  seek,
  setRate,
  setVolume,
  setMuted,
  setSystemVolume,
  previousEpisode,
  nextEpisode,
  selectEpisode,
  handoff,
  navigate,
  beginTextInput,
  updateTextInput,
  submitTextInput,
  cancelTextInput,
  exitPlayback,
}

/// A bounded, typed command received from a paired companion client.
final class CompanionCommand {
  const CompanionCommand({
    required this.id,
    required this.hostEpoch,
    required this.clientSeq,
    required this.controlGeneration,
    required this.playbackGeneration,
    required this.deadlineMs,
    required this.type,
    this.arguments = const <String, Object?>{},
  });

  static const int maxIdLength = 128;
  static const int maxHostEpochLength = 128;
  static const int maxArgumentsBytes = 16 * 1024;
  static const int maxArgumentsDepth = 12;
  static const int maxArgumentCollectionLength = 256;

  final String id;
  final String hostEpoch;
  final int clientSeq;
  final int controlGeneration;
  final int playbackGeneration;
  final int deadlineMs;
  final CompanionCommandType type;
  final Map<String, Object?> arguments;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'hostEpoch': hostEpoch,
    'clientSeq': clientSeq,
    'controlGeneration': controlGeneration,
    'playbackGeneration': playbackGeneration,
    'deadlineMs': deadlineMs,
    'type': type.name,
    'arguments': arguments,
  };

  String fingerprint() => jsonEncode(_canonicalize(toJson()));

  static CompanionCommand fromJson(Object? value) {
    final map = _strictObject(value, 'command');
    const required = <String>{'id', 'hostEpoch', 'clientSeq', 'controlGeneration', 'playbackGeneration', 'deadlineMs', 'type', 'arguments'};
    _requireExactKeys(map, required, 'command');
    final id = _requiredString(map, 'id', maxLength: maxIdLength);
    final epoch = _requiredString(map, 'hostEpoch', maxLength: maxHostEpochLength);
    if (id.isEmpty || epoch.isEmpty) {
      throw const FormatException('id and hostEpoch must not be empty');
    }
    final rawType = _requiredString(map, 'type', maxLength: 64);
    final type = CompanionCommandType.values.cast<CompanionCommandType?>().firstWhere(
      (candidate) => candidate?.name == rawType,
      orElse: () => null,
    );
    if (type == null) throw FormatException('Unknown command type: $rawType');
    final rawArguments = _strictObject(map['arguments'], 'arguments');
    _validateJsonValue(rawArguments, 0);
    if (utf8.encode(jsonEncode(rawArguments)).length > maxArgumentsBytes) {
      throw const FormatException('arguments exceed the protocol size limit');
    }
    return CompanionCommand(
      id: id,
      hostEpoch: epoch,
      clientSeq: _requiredNonNegativeInt(map, 'clientSeq'),
      controlGeneration: _requiredNonNegativeInt(map, 'controlGeneration'),
      playbackGeneration: _requiredNonNegativeInt(map, 'playbackGeneration'),
      deadlineMs: _requiredNonNegativeInt(map, 'deadlineMs'),
      type: type,
      arguments: Map<String, Object?>.unmodifiable(rawArguments),
    );
  }
}

enum CompanionCommandPhase { received, accepted, preparing, resolving, buffering, applied, started, failed, cancelled, expired, superseded }

/// A command lifecycle update. `peerId` is included so a shared stream can be
/// routed back to the originating connection.
final class CompanionReceipt {
  const CompanionReceipt({
    required this.peerId,
    required this.commandId,
    required this.phase,
    this.code,
    this.details = const <String, Object?>{},
  });

  final String peerId;
  final String commandId;
  final CompanionCommandPhase phase;
  final String? code;
  final Map<String, Object?> details;

  bool get isTerminal => switch (phase) {
    CompanionCommandPhase.applied ||
    CompanionCommandPhase.started ||
    CompanionCommandPhase.failed ||
    CompanionCommandPhase.cancelled ||
    CompanionCommandPhase.expired ||
    CompanionCommandPhase.superseded => true,
    _ => false,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'peerId': peerId,
    'commandId': commandId,
    'phase': phase.name,
    if (code != null) 'code': code,
    'details': details,
  };

  static CompanionReceipt fromJson(Object? value) {
    final map = _strictObject(value, 'receipt');
    const allowed = <String>{'peerId', 'commandId', 'phase', 'code', 'details'};
    const required = <String>{'peerId', 'commandId', 'phase', 'details'};
    _requireExactKeys(map, required, 'receipt', allowed: allowed);
    final phaseName = _requiredString(map, 'phase', maxLength: 32);
    final phase = CompanionCommandPhase.values.cast<CompanionCommandPhase?>().firstWhere(
      (candidate) => candidate?.name == phaseName,
      orElse: () => null,
    );
    if (phase == null) throw FormatException('Unknown receipt phase: $phaseName');
    final details = _strictObject(map['details'], 'details');
    _validateJsonValue(details, 0);
    if (utf8.encode(jsonEncode(details)).length > CompanionCommand.maxArgumentsBytes) {
      throw const FormatException('receipt details exceed the protocol size limit');
    }
    final code = map['code'];
    if (code != null && (code is! String || code.length > 128)) {
      throw const FormatException('receipt code must be a short string');
    }
    return CompanionReceipt(
      peerId: _requiredString(map, 'peerId', maxLength: 128),
      commandId: _requiredString(map, 'commandId', maxLength: CompanionCommand.maxIdLength),
      phase: phase,
      code: code as String?,
      details: Map<String, Object?>.unmodifiable(details),
    );
  }
}

Map<String, Object?> _strictObject(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be a JSON object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) throw FormatException('$label keys must be strings');
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _requireExactKeys(Map<String, Object?> map, Set<String> required, String label, {Set<String>? allowed}) {
  final accepted = allowed ?? required;
  final unknown = map.keys.where((key) => !accepted.contains(key));
  final missing = required.where((key) => !map.containsKey(key));
  if (unknown.isNotEmpty || missing.isNotEmpty) {
    throw FormatException('$label has missing or unknown fields');
  }
}

String _requiredString(Map<String, Object?> map, String key, {required int maxLength}) {
  final value = map[key];
  if (value is! String || value.length > maxLength) {
    throw FormatException('$key must be a string of at most $maxLength characters');
  }
  return value;
}

int _requiredNonNegativeInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int || value < 0) throw FormatException('$key must be a non-negative integer');
  return value;
}

void _validateJsonValue(Object? value, int depth) {
  if (depth > CompanionCommand.maxArgumentsDepth) {
    throw const FormatException('JSON nesting exceeds the protocol limit');
  }
  if (value == null || value is String || value is bool || value is int) return;
  if (value is double) {
    if (!value.isFinite) throw const FormatException('JSON numbers must be finite');
    return;
  }
  if (value is List) {
    if (value.length > CompanionCommand.maxArgumentCollectionLength) {
      throw const FormatException('JSON array exceeds the protocol item limit');
    }
    for (final item in value) {
      _validateJsonValue(item, depth + 1);
    }
    return;
  }
  if (value is Map) {
    if (value.length > CompanionCommand.maxArgumentCollectionLength) {
      throw const FormatException('JSON object exceeds the protocol item limit');
    }
    for (final entry in value.entries) {
      if (entry.key is! String) throw const FormatException('JSON object keys must be strings');
      _validateJsonValue(entry.value, depth + 1);
    }
    return;
  }
  throw FormatException('Unsupported JSON value: ${value.runtimeType}');
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}
