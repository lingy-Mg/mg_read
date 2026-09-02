import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/errors/app_error.dart';

void main() {
  group('AppError', () {
    test('maps stable wire codes to actionable categories', () {
      final AppError rateLimited = AppError.fromWireCode('rate_limited');
      final AppError missingPlugin = AppError.fromWireCode('plugin_not_found');
      final AppError outOfSpace = AppError.fromWireCode('disk_full');
      final AppError mediaResolver = AppError.fromWireCode('source_media_resolution_failed');

      expect(rateLimited.retryable, isTrue);
      expect(rateLimited.category, AppErrorCategory.retryableTemporary);
      expect(missingPlugin.category, AppErrorCategory.pluginUnavailable);
      expect(outOfSpace.category, AppErrorCategory.storagePressure);
      expect(mediaResolver.retryable, isTrue);
      expect(mediaResolver.category, AppErrorCategory.retryableTemporary);
    });

    test('normalizes unknown protocol values and exception messages', () {
      final AppError unknownWire = AppError.fromWireCode('upstream_secret');
      final AppError unknownException = AppError.fromUnknown(StateError('do not expose this upstream message'));

      expect(unknownWire.code, AppErrorCode.internal);
      expect(unknownException.code, AppErrorCode.internal);
      expect(unknownException.toString(), isNot(contains('do not expose this upstream message')));
    });
  });
}
