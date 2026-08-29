import 'dart:collection';
import 'dart:convert';

/// A size and shape budget for small diagnostic attributes.
final class DiagnosticValueBudget {
  const DiagnosticValueBudget({
    this.maxEncodedBytes = 16 * 1024,
    this.maxDepth = 8,
    this.maxObjectKeys = 128,
    this.maxArrayItems = 256,
    this.maxStringBytes = 4 * 1024,
    this.maxNodes = 1024,
  });

  final int maxEncodedBytes;
  final int maxDepth;
  final int maxObjectKeys;
  final int maxArrayItems;
  final int maxStringBytes;
  final int maxNodes;

  void validate() {
    if (maxEncodedBytes <= 0 || maxDepth <= 0 || maxObjectKeys <= 0 || maxArrayItems <= 0 || maxStringBytes <= 0 || maxNodes <= 0) {
      throw ArgumentError('Diagnostic value budgets must all be positive.');
    }
  }
}

/// Base type for data allowed in a small diagnostic event.
///
/// Every subtype has an explicit wire representation. Arbitrary objects and
/// their `toString`/`toJson` methods are never invoked by this model.
sealed class DiagnosticValue {
  const DiagnosticValue();

  Object toWireValue();

  int get encodedByteLength => utf8.encode(jsonEncode(toWireValue())).length;

  static const DiagnosticNullValue nullValue = DiagnosticNullValue();

  static DiagnosticValue boolean(bool value) => DiagnosticBoolValue(value);

  static DiagnosticValue string(String value) => DiagnosticStringValue(value);

  static DiagnosticValue int64(int value) => DiagnosticInt64Value(value.toString());

  static DiagnosticValue finiteDouble(double value) => DiagnosticDoubleValue(value);

  static DiagnosticListValue list(Iterable<DiagnosticValue> values) => DiagnosticListValue(values);

  static DiagnosticObjectValue object(Map<String, DiagnosticValue> values) => DiagnosticObjectValue(values);

  static DiagnosticTruncatedValue truncated({required String reason, int? originalCount}) =>
      DiagnosticTruncatedValue(reason: reason, originalCount: originalCount);

  static DiagnosticAttachmentReferenceValue attachment(String attachmentId) => DiagnosticAttachmentReferenceValue(attachmentId);
}

final class DiagnosticNullValue extends DiagnosticValue {
  const DiagnosticNullValue();

  @override
  Object toWireValue() => const <String, Object?>{'type': 'null'};

  @override
  bool operator ==(Object other) => other is DiagnosticNullValue;

  @override
  int get hashCode => 0;
}

final class DiagnosticBoolValue extends DiagnosticValue {
  const DiagnosticBoolValue(this.value);

  final bool value;

  @override
  Object toWireValue() => <String, Object?>{'type': 'bool', 'value': value};

  @override
  bool operator ==(Object other) => other is DiagnosticBoolValue && other.value == value;

  @override
  int get hashCode => Object.hash(DiagnosticBoolValue, value);
}

final class DiagnosticStringValue extends DiagnosticValue {
  DiagnosticStringValue(this.value) {
    if (value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'NUL is not allowed.');
    }
  }

  final String value;

  @override
  Object toWireValue() => <String, Object?>{'type': 'string', 'value': value};

  @override
  bool operator ==(Object other) => other is DiagnosticStringValue && other.value == value;

  @override
  int get hashCode => Object.hash(DiagnosticStringValue, value);
}

final class DiagnosticInt64Value extends DiagnosticValue {
  DiagnosticInt64Value(this.decimal) {
    if (!_canonicalInt64.hasMatch(decimal)) {
      throw ArgumentError.value(decimal, 'decimal', 'Not a canonical int64.');
    }
    final value = BigInt.parse(decimal);
    if (value < _minimumInt64 || value > _maximumInt64) {
      throw RangeError('decimal is outside the signed int64 range.');
    }
  }

  static final RegExp _canonicalInt64 = RegExp(r'^(0|-?[1-9][0-9]*)$');
  static final BigInt _minimumInt64 = BigInt.parse('-9223372036854775808');
  static final BigInt _maximumInt64 = BigInt.parse('9223372036854775807');

  final String decimal;

  @override
  Object toWireValue() => <String, Object?>{'type': 'int64', 'decimal': decimal};

  @override
  bool operator ==(Object other) => other is DiagnosticInt64Value && other.decimal == decimal;

  @override
  int get hashCode => Object.hash(DiagnosticInt64Value, decimal);
}

final class DiagnosticDoubleValue extends DiagnosticValue {
  DiagnosticDoubleValue(this.value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Only finite doubles work.');
    }
  }

  final double value;

  @override
  Object toWireValue() => <String, Object?>{'type': 'finiteDouble', 'value': value};

  @override
  bool operator ==(Object other) => other is DiagnosticDoubleValue && other.value == value;

  @override
  int get hashCode => Object.hash(DiagnosticDoubleValue, value);
}

final class DiagnosticListValue extends DiagnosticValue {
  DiagnosticListValue(Iterable<DiagnosticValue> values) : values = List<DiagnosticValue>.unmodifiable(values);

  final List<DiagnosticValue> values;

  @override
  Object toWireValue() => <String, Object?>{'type': 'list', 'values': values.map((value) => value.toWireValue()).toList(growable: false)};

  @override
  bool operator ==(Object other) => other is DiagnosticListValue && _listEquals(other.values, values);

  @override
  int get hashCode => Object.hashAll(values);
}

final class DiagnosticObjectValue extends DiagnosticValue {
  DiagnosticObjectValue(Map<String, DiagnosticValue> values)
    : values = UnmodifiableMapView<String, DiagnosticValue>(SplayTreeMap<String, DiagnosticValue>.from(values)) {
    for (final key in values.keys) {
      _validateKey(key);
    }
  }

  static final DiagnosticObjectValue empty = DiagnosticObjectValue(const {});

  final Map<String, DiagnosticValue> values;

  DiagnosticObjectValue merged(DiagnosticObjectValue other) => DiagnosticObjectValue(<String, DiagnosticValue>{...values, ...other.values});

  @override
  Object toWireValue() => <String, Object?>{
    'type': 'object',
    'values': <String, Object?>{for (final entry in values.entries) entry.key: entry.value.toWireValue()},
  };

  @override
  bool operator ==(Object other) => other is DiagnosticObjectValue && _mapEquals(other.values, values);

  @override
  int get hashCode => Object.hashAll(values.entries.map((entry) => Object.hash(entry.key, entry.value)));
}

final class DiagnosticTruncatedValue extends DiagnosticValue {
  const DiagnosticTruncatedValue({required this.reason, this.originalCount});

  final String reason;
  final int? originalCount;

  @override
  Object toWireValue() => <String, Object?>{'type': 'truncated', 'reason': reason, 'originalCount': ?originalCount};

  @override
  bool operator ==(Object other) => other is DiagnosticTruncatedValue && other.reason == reason && other.originalCount == originalCount;

  @override
  int get hashCode => Object.hash(DiagnosticTruncatedValue, reason, originalCount);
}

final class DiagnosticAttachmentReferenceValue extends DiagnosticValue {
  DiagnosticAttachmentReferenceValue(this.attachmentId) {
    if (!_opaqueId.hasMatch(attachmentId)) {
      throw ArgumentError.value(attachmentId, 'attachmentId');
    }
  }

  static final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

  final String attachmentId;

  @override
  Object toWireValue() => <String, Object?>{'type': 'attachmentRef', 'attachmentId': attachmentId};

  @override
  bool operator ==(Object other) => other is DiagnosticAttachmentReferenceValue && other.attachmentId == attachmentId;

  @override
  int get hashCode => Object.hash(DiagnosticAttachmentReferenceValue, attachmentId);
}

/// Converts JSON-compatible values into the bounded tagged union.
///
/// Unsupported values fail without calling `toString` or `toJson`.
final class DiagnosticValueBuilder {
  DiagnosticValueBuilder({this.budget = const DiagnosticValueBudget()}) {
    budget.validate();
  }

  final DiagnosticValueBudget budget;

  DiagnosticObjectValue buildAttributes(Map<String, Object?> source) {
    final state = _DiagnosticBuildState(budget);
    final result = _build(source, state, depth: 0);
    if (result is! DiagnosticObjectValue) {
      throw const DiagnosticValueBuildError('Diagnostic attributes must encode as an object.');
    }
    if (result.encodedByteLength > budget.maxEncodedBytes) {
      throw DiagnosticValueBuildError('Diagnostic attributes exceed ${budget.maxEncodedBytes} bytes.');
    }
    return result;
  }

  DiagnosticValue build(Object? source) {
    final value = _build(source, _DiagnosticBuildState(budget), depth: 0);
    if (value.encodedByteLength > budget.maxEncodedBytes) {
      return DiagnosticValue.truncated(reason: 'encodedByteLimit', originalCount: value.encodedByteLength);
    }
    return value;
  }

  DiagnosticValue _build(Object? source, _DiagnosticBuildState state, {required int depth}) {
    if (depth > budget.maxDepth) {
      return DiagnosticValue.truncated(reason: 'depthLimit');
    }
    if (!state.consumeNode()) {
      return DiagnosticValue.truncated(reason: 'nodeLimit');
    }
    if (source == null) return DiagnosticValue.nullValue;
    if (source is bool) return DiagnosticValue.boolean(source);
    if (source is String) {
      final bytes = utf8.encode(source).length;
      if (bytes > budget.maxStringBytes) {
        return DiagnosticValue.truncated(reason: 'stringByteLimit', originalCount: bytes);
      }
      return DiagnosticValue.string(source);
    }
    if (source is int) return DiagnosticValue.int64(source);
    if (source is double) {
      if (!source.isFinite) {
        throw const DiagnosticValueBuildError('Non-finite doubles require an explicit diagnostic-tree adapter.');
      }
      return DiagnosticValue.finiteDouble(source);
    }
    if (source is List<Object?>) {
      if (!state.enter(source)) {
        return DiagnosticValue.truncated(reason: 'cycle');
      }
      try {
        if (source.length > budget.maxArrayItems) {
          return DiagnosticValue.truncated(reason: 'arrayItemLimit', originalCount: source.length);
        }
        return DiagnosticValue.list(source.map((value) => _build(value, state, depth: depth + 1)));
      } finally {
        state.leave(source);
      }
    }
    if (source is Map<String, Object?>) {
      if (!state.enter(source)) {
        return DiagnosticValue.truncated(reason: 'cycle');
      }
      try {
        if (source.length > budget.maxObjectKeys) {
          return DiagnosticValue.truncated(reason: 'objectKeyLimit', originalCount: source.length);
        }
        final keys = source.keys.toList(growable: false)..sort();
        return DiagnosticValue.object(<String, DiagnosticValue>{for (final key in keys) key: _build(source[key], state, depth: depth + 1)});
      } finally {
        state.leave(source);
      }
    }
    throw DiagnosticValueBuildError('Unsupported diagnostic value type: ${source.runtimeType}.');
  }
}

final class DiagnosticValueCodec {
  const DiagnosticValueCodec();

  DiagnosticValue decode(Object? wireValue) {
    if (wireValue is! Map<Object?, Object?>) {
      throw const FormatException('Diagnostic value must be an object.');
    }
    final type = wireValue['type'];
    if (type is! String) {
      throw const FormatException('Diagnostic value type is missing.');
    }
    return switch (type) {
      'null' => DiagnosticValue.nullValue,
      'bool' => DiagnosticValue.boolean(_required<bool>(wireValue, 'value')),
      'string' => DiagnosticValue.string(_required<String>(wireValue, 'value')),
      'int64' => DiagnosticInt64Value(_required<String>(wireValue, 'decimal')),
      'finiteDouble' => DiagnosticValue.finiteDouble(_required<num>(wireValue, 'value').toDouble()),
      'list' => DiagnosticValue.list(_required<List<Object?>>(wireValue, 'values').map(decode)),
      'object' => _decodeObject(wireValue),
      'truncated' => DiagnosticValue.truncated(
        reason: _required<String>(wireValue, 'reason'),
        originalCount: wireValue['originalCount'] as int?,
      ),
      'attachmentRef' => DiagnosticValue.attachment(_required<String>(wireValue, 'attachmentId')),
      _ => throw FormatException('Unsupported diagnostic value type: $type.'),
    };
  }

  DiagnosticObjectValue _decodeObject(Map<Object?, Object?> wireValue) {
    final raw = _required<Map<Object?, Object?>>(wireValue, 'values');
    final result = <String, DiagnosticValue>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        throw const FormatException('Diagnostic object keys must be strings.');
      }
      result[entry.key! as String] = decode(entry.value);
    }
    return DiagnosticValue.object(result);
  }

  T _required<T>(Map<Object?, Object?> value, String key) {
    final field = value[key];
    if (field is! T) {
      throw FormatException('Diagnostic value field "$key" is invalid.');
    }
    return field;
  }
}

final class DiagnosticValueBuildError implements Exception {
  const DiagnosticValueBuildError(this.message);

  final String message;

  @override
  String toString() => 'DiagnosticValueBuildError: $message';
}

final class _DiagnosticBuildState {
  _DiagnosticBuildState(this.budget);

  final DiagnosticValueBudget budget;
  final Set<Object> _ancestors = HashSet<Object>.identity();
  int _nodeCount = 0;

  bool consumeNode() {
    _nodeCount += 1;
    return _nodeCount <= budget.maxNodes;
  }

  bool enter(Object value) => _ancestors.add(value);

  void leave(Object value) => _ancestors.remove(value);
}

void _validateKey(String key) {
  if (key.isEmpty || key.length > 128 || !_diagnosticKey.hasMatch(key)) {
    throw ArgumentError.value(key, 'key', 'Diagnostic keys must be stable lower camel/snake/dot identifiers.');
  }
}

final RegExp _diagnosticKey = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,127}$');

bool _listEquals(List<DiagnosticValue> a, List<DiagnosticValue> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, DiagnosticValue> a, Map<String, DiagnosticValue> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
