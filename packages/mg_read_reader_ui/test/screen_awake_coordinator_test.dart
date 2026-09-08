/// Aggregate display-awake policy for concurrent reader and host requests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bright holder overrides dimming holder until released', () async {
    final ReaderPlatform previousPlatform = ReaderPlatform.instance;
    final _RecordingReaderPlatform platform = _RecordingReaderPlatform();
    final Object audio = Object();
    final Object reader = Object();
    ReaderPlatform.instance = platform;
    try {
      await ScreenAwakeCoordinator.instance.acquire(
        audio,
        allowScreenDimming: true,
      );
      expect(platform.requests.last, 'on/dim/bars');

      await ScreenAwakeCoordinator.instance.acquire(reader);
      expect(platform.requests.last, 'on/bright/bars');

      await ScreenAwakeCoordinator.instance.release(reader);
      expect(platform.requests.last, 'on/dim/bars');

      await ScreenAwakeCoordinator.instance.release(audio);
      expect(platform.requests.last, 'off/bright/bars');
    } finally {
      await ScreenAwakeCoordinator.instance.release(reader);
      await ScreenAwakeCoordinator.instance.release(audio);
      ReaderPlatform.instance = previousPlatform;
    }
  });
}

final class _RecordingReaderPlatform extends ReaderPlatform {
  final List<String> requests = <String>[];

  @override
  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
    bool allowScreenDimming = false,
  }) async {
    requests.add(
      '${keepScreenOn ? 'on' : 'off'}/'
      '${allowScreenDimming ? 'dim' : 'bright'}/'
      '${immersiveMode ? 'immersive' : 'bars'}',
    );
  }
}
