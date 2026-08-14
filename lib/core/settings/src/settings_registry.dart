import 'dart:collection';

import 'setting_key.dart';

typedef SettingsDocumentValidator =
    void Function(Map<String, Object?> document);
typedef SettingsDocumentUpgrader =
    Map<String, Object?> Function(Map<String, Object?> document);

const int settingsDocumentMaxEncodedBytes = 64 * 1024;
const int settingsDocumentMaxDepth = 8;
const int settingsDocumentMaxKeys = 256;
const int settingsDocumentMaxNodes = 1024;
const int settingsDocumentMaxArrayLength = 256;
const int settingsDocumentMaxStringLength = 8192;
const int settingsMaxDocumentGroups = 128;
const Set<String> forbiddenSettingsJsonKeyTokens = {
  'authorization',
  'cookie',
  'credential',
  'credentials',
  'passwd',
  'password',
  'secret',
  'secrets',
  'token',
  'tokens',
};

final class SettingsDocumentDefinition {
  const SettingsDocumentDefinition({
    required this.id,
    required this.kind,
    this.currentVersion = 1,
    this.validators = const {},
    this.upgraders = const {},
  });

  final String id;
  final String kind;
  final int currentVersion;
  final Map<int, SettingsDocumentValidator> validators;
  final Map<int, SettingsDocumentUpgrader> upgraders;
}

final class SettingsRegistry {
  SettingsRegistry({
    required Iterable<SettingKey<dynamic>> keys,
    required Iterable<SettingsDocumentDefinition> documents,
  }) : keys = UnmodifiableMapView(_indexKeys(keys)),
       documents = UnmodifiableMapView(_indexDocuments(documents)) {
    if (this.documents.length > settingsMaxDocumentGroups) {
      throw ArgumentError(
        'Settings cannot register more than $settingsMaxDocumentGroups document groups.',
      );
    }
    final defaults = <String, Object?>{};
    for (final key in this.keys.values) {
      if (!this.documents.containsKey(key.documentKind)) {
        throw ArgumentError(
          'Setting ${key.id} references an unregistered document.',
        );
      }
      _validateIdentifier(key.id, label: 'setting ID');
      _rejectSensitiveIdentifier(key.id);
      key.validateValue(key.defaultValue);
      final encoded = key.encodeValue(key.defaultValue);
      _validateBoundedJsonValue(encoded);
      final decoded = key.decodeValue(encoded);
      key.validateValue(decoded);
      defaults[key.id] = key.freezeValue(decoded);
    }
    for (final document in this.documents.values) {
      _validateIdentifier(document.kind, label: 'document kind');
      if (document.id.isEmpty || document.id.length > 160) {
        throw ArgumentError.value(document.id, 'document.id');
      }
      _rejectSensitiveIdentifier(document.id);
      if (document.currentVersion < 1) {
        throw ArgumentError.value(document.currentVersion, 'currentVersion');
      }
      if (document.validators.isNotEmpty) {
        for (var version = 1; version <= document.currentVersion; version++) {
          if (!document.validators.containsKey(version)) {
            throw ArgumentError(
              'Document ${document.kind} has no validator for version $version.',
            );
          }
        }
      }
      for (var version = 1; version < document.currentVersion; version++) {
        if (!document.upgraders.containsKey(version)) {
          throw ArgumentError(
            'Document ${document.kind} has no upgrader from version $version.',
          );
        }
      }
    }
    defaultValues = UnmodifiableMapView(defaults);
  }

  factory SettingsRegistry.fromKeys(Iterable<SettingKey<dynamic>> keys) {
    final copied = List<SettingKey<dynamic>>.of(keys);
    final kinds = copied.map((key) => key.documentKind).toSet();
    return SettingsRegistry(
      keys: copied,
      documents: [
        for (final kind in kinds)
          SettingsDocumentDefinition(id: 'app-settings:$kind', kind: kind),
      ],
    );
  }

  final Map<String, SettingKey<dynamic>> keys;
  final Map<String, SettingsDocumentDefinition> documents;
  late final Map<String, Object?> defaultValues;

  SettingKey<dynamic> requireKey(String id) {
    final key = keys[id];
    if (key == null) {
      throw ArgumentError.value(id, 'id', 'Unregistered setting key.');
    }
    return key;
  }

  SettingsDocumentDefinition requireDocument(String kind) {
    final document = documents[kind];
    if (document == null) {
      throw ArgumentError.value(
        kind,
        'kind',
        'Unregistered settings document.',
      );
    }
    return document;
  }

  Iterable<SettingKey<dynamic>> keysForDocument(String kind) =>
      keys.values.where((key) => key.documentKind == kind);
}

Map<String, SettingKey<dynamic>> _indexKeys(
  Iterable<SettingKey<dynamic>> keys,
) {
  final result = <String, SettingKey<dynamic>>{};
  for (final key in keys) {
    if (result.containsKey(key.id)) {
      throw ArgumentError('Duplicate setting ID ${key.id}.');
    }
    result[key.id] = key;
  }
  return result;
}

Map<String, SettingsDocumentDefinition> _indexDocuments(
  Iterable<SettingsDocumentDefinition> documents,
) {
  final result = <String, SettingsDocumentDefinition>{};
  final ids = <String>{};
  for (final document in documents) {
    if (result.containsKey(document.kind)) {
      throw ArgumentError('Duplicate settings document ${document.kind}.');
    }
    if (!ids.add(document.id)) {
      throw ArgumentError('Duplicate settings document ID ${document.id}.');
    }
    result[document.kind] = document;
  }
  return result;
}

void _validateIdentifier(String value, {required String label}) {
  if (value.isEmpty ||
      value.length > 128 ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$').hasMatch(value)) {
    throw ArgumentError.value(value, label);
  }
}

void _rejectSensitiveIdentifier(String value) {
  final separated = value.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match[1]}.${match[2]}',
  );
  final normalized = separated.toLowerCase();
  final tokens = normalized
      .split(RegExp('[^a-z0-9]+'))
      .where((token) => token.isNotEmpty)
      .toSet();
  if (tokens.any(forbiddenSettingsJsonKeyTokens.contains) ||
      normalized.contains('request.body') ||
      normalized.contains('response.body') ||
      normalized.contains('chapter.text') ||
      normalized.contains('raw.html') ||
      normalized.contains('plain.text') ||
      normalized.contains('binary.blob') ||
      normalized.contains('absolute.path')) {
    throw ArgumentError('Settings cannot register sensitive or body fields.');
  }
}

void validateSettingsEncodedValue(Object? value) {
  _validateBoundedJsonValue(value);
}

void _validateBoundedJsonValue(Object? root) {
  var keys = 0;
  var nodes = 0;
  var estimatedEncodedBytes = 2;
  void visit(Object? value, int depth) {
    nodes++;
    if (nodes > settingsDocumentMaxNodes || depth > settingsDocumentMaxDepth) {
      throw ArgumentError('Setting value exceeds the JSON complexity limit.');
    }
    if (value is String) {
      estimatedEncodedBytes += value.length * 4 + 2;
      if (value.length > settingsDocumentMaxStringLength) {
        throw ArgumentError('Setting string exceeds the size limit.');
      }
      return;
    }
    if (value == null || value is bool || value is num && value.isFinite) {
      estimatedEncodedBytes += 32;
      return;
    }
    if (value is List) {
      if (value.length > settingsDocumentMaxArrayLength) {
        throw ArgumentError('Setting array exceeds the size limit.');
      }
      for (final child in value) {
        visit(child, depth + 1);
      }
      return;
    }
    if (value is Map) {
      keys += value.length;
      if (keys > settingsDocumentMaxKeys) {
        throw ArgumentError('Setting object exceeds the key limit.');
      }
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw ArgumentError('Setting object keys must be strings.');
        }
        final key = entry.key as String;
        estimatedEncodedBytes += key.length * 4 + 4;
        _rejectSensitiveIdentifier(key);
        visit(entry.value, depth + 1);
      }
      return;
    }
    throw ArgumentError('Setting codecs may only produce JSON values.');
  }

  visit(root, 0);
  if (estimatedEncodedBytes > settingsDocumentMaxEncodedBytes) {
    throw ArgumentError('Setting value exceeds the encoded size limit.');
  }
}
