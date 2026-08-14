import 'dart:convert';

import 'diagnostic_event.dart';
import 'diagnostic_registry.dart';
import 'diagnostic_value.dart';

/// Context supplied by an explicit, bounded capture session.
final class DiagnosticPrivacyContext {
  const DiagnosticPrivacyContext({
    this.payloadKind = DiagnosticPayloadKind.metadataOnly,
    this.hasExplicitCaptureSession = false,
    this.allowRestrictedRaw = false,
  });

  final DiagnosticPayloadKind payloadKind;
  final bool hasExplicitCaptureSession;
  final bool allowRestrictedRaw;
}

/// Central policy preventing callers from inventing their own redaction rules.
final class DiagnosticPrivacyPolicy {
  DiagnosticPrivacyPolicy({
    Set<String> secretFieldNames = const <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'password',
      'passwd',
      'token',
      'access_token',
      'refresh_token',
      'credential',
      'credentials',
      'secret',
      'api_key',
      'api-key',
      'x-api-key',
    },
  }) : _secretFieldNames = secretFieldNames
           .map((value) => value.toLowerCase())
           .toSet();

  final Set<String> _secretFieldNames;

  bool isSecretFieldName(String name) {
    final normalized = name.toLowerCase();
    if (_secretFieldNames.contains(normalized)) return true;
    return normalized.endsWith('token') ||
        normalized.endsWith('password') ||
        normalized.endsWith('credential') ||
        normalized.endsWith('secret');
  }

  DiagnosticObjectValue sanitizeAttributes({
    required DiagnosticEventDefinition definition,
    required DiagnosticObjectValue attributes,
    DiagnosticPrivacyContext context = const DiagnosticPrivacyContext(),
  }) {
    final result = <String, DiagnosticValue>{};
    for (final entry in attributes.values.entries) {
      final field = definition.fields[entry.key];
      if (field == null) {
        throw DiagnosticSchemaError(
          '${definition.name} has no field named ${entry.key}.',
        );
      }
      result[entry.key] = _sanitizeValue(
        entry.value,
        field.privacyClass,
        context,
        fieldName: entry.key,
      );
    }
    return DiagnosticObjectValue(result);
  }

  DiagnosticValue sanitizeStructuredValue(
    DiagnosticValue value, {
    required DiagnosticPrivacyClass privacyClass,
    required DiagnosticPrivacyContext context,
  }) => _sanitizeValue(value, privacyClass, context);

  DiagnosticValue _sanitizeValue(
    DiagnosticValue value,
    DiagnosticPrivacyClass privacyClass,
    DiagnosticPrivacyContext context, {
    String? fieldName,
  }) {
    if (fieldName != null && isSecretFieldName(fieldName)) {
      return DiagnosticValue.redacted(reason: 'secretField');
    }
    if (!_privacyClassAllowed(privacyClass, context)) {
      return DiagnosticValue.redacted(reason: privacyClass.name);
    }
    if (value is DiagnosticObjectValue) {
      return DiagnosticObjectValue(<String, DiagnosticValue>{
        for (final entry in value.values.entries)
          entry.key: _sanitizeValue(
            entry.value,
            privacyClass,
            context,
            fieldName: entry.key,
          ),
      });
    }
    if (value is DiagnosticListValue) {
      return DiagnosticListValue(
        value.values.map((item) => _sanitizeValue(item, privacyClass, context)),
      );
    }
    return value;
  }

  bool _privacyClassAllowed(
    DiagnosticPrivacyClass privacyClass,
    DiagnosticPrivacyContext context,
  ) => switch (privacyClass) {
    DiagnosticPrivacyClass.public || DiagnosticPrivacyClass.internal => true,
    DiagnosticPrivacyClass.content =>
      context.hasExplicitCaptureSession &&
          (context.payloadKind == DiagnosticPayloadKind.safeStructured ||
              context.payloadKind == DiagnosticPayloadKind.contentPayload ||
              context.payloadKind == DiagnosticPayloadKind.restrictedRaw),
    DiagnosticPrivacyClass.restricted =>
      context.hasExplicitCaptureSession &&
          context.payloadKind == DiagnosticPayloadKind.restrictedRaw &&
          context.allowRestrictedRaw,
    DiagnosticPrivacyClass.secret => false,
  };

  /// Produces an origin/route/query-key projection without URL values.
  DiagnosticObjectValue projectUrl(Uri uri, {String? routeTemplate}) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final includePort =
        uri.hasPort &&
        !((scheme == 'http' && uri.port == 80) ||
            (scheme == 'https' && uri.port == 443));
    final origin = host.isEmpty
        ? 'invalid-origin'
        : '$scheme://$host${includePort ? ':${uri.port}' : ''}';
    final queryKeys = uri.queryParametersAll.keys.toList(growable: false)
      ..sort();
    return DiagnosticObjectValue(<String, DiagnosticValue>{
      'origin': DiagnosticValue.string(origin),
      'route': DiagnosticValue.string(routeTemplate ?? _routeShape(uri)),
      'queryKeys': DiagnosticValue.list(queryKeys.map(DiagnosticValue.string)),
    });
  }

  /// Keeps only explicitly safe HTTP header values; all secret values vanish.
  DiagnosticObjectValue sanitizeHeaders(
    Map<String, List<String>> headers, {
    Set<String> safeValueNames = const <String>{
      'accept',
      'accept-encoding',
      'content-encoding',
      'content-length',
      'content-type',
      'range',
      'retry-after',
    },
  }) {
    final normalizedSafeNames = safeValueNames
        .map((name) => name.toLowerCase())
        .toSet();
    final values = <String, DiagnosticValue>{};
    final entries = headers.entries.toList(growable: false)
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    for (final entry in entries) {
      final name = entry.key.toLowerCase();
      if (isSecretFieldName(name)) {
        values[name] = DiagnosticValue.redacted(reason: 'secretHeader');
      } else if (normalizedSafeNames.contains(name)) {
        values[name] = DiagnosticValue.list(
          entry.value.map((value) => DiagnosticValue.string(_short(value))),
        );
      } else {
        values[name] = DiagnosticValue.redacted(reason: 'headerValueBlocked');
      }
    }
    return DiagnosticObjectValue(values);
  }

  /// Returns a non-reversible fingerprint of a cleaned stack shape.
  String stackFingerprint(StackTrace stackTrace) {
    final cleaned = stackTrace
        .toString()
        .replaceAll(_windowsAbsolutePath, '<path>')
        .replaceAll(_unixAbsolutePath, '<path>')
        .replaceAll(_queryValue, r'$1=<redacted>')
        .replaceAll(RegExp(r':\d+:\d+'), ':<line>:<column>');
    final bytes = utf8.encode(cleaned);
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in bytes) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  String _routeShape(Uri uri) {
    if (uri.pathSegments.isEmpty) return '/';
    return '/${List<String>.filled(uri.pathSegments.length, '{segment}').join('/')}';
  }

  String _short(String value) {
    final singleLine = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (singleLine.length <= 256) return singleLine;
    return '${singleLine.substring(0, 256)}…';
  }
}

final RegExp _windowsAbsolutePath = RegExp(
  r'(?:[a-z]:\\|\\\\)[^\s\)\]]+',
  caseSensitive: false,
);
final RegExp _unixAbsolutePath = RegExp(
  r'(?<![A-Za-z0-9])/(?:[^\s/]+/)+[^\s\)\]]+',
);
final RegExp _queryValue = RegExp(r'([?&][A-Za-z0-9_.-]+)=[^&#\s]*');
