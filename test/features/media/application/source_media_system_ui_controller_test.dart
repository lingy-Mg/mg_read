/// Verifies shared audio/video ownership of immersive system UI.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_media_system_ui_controller.dart';

void main() {
  test('keeps immersive UI while ownership passes from audio to video', () async {
    final platform = _FakeSystemUiPlatform();
    final coordinator = SourceMediaSystemUiCoordinator.withPlatform(platform);
    final audio = SourceMediaSystemUiLease.withCoordinator(coordinator);
    final video = SourceMediaSystemUiLease.withCoordinator(coordinator);

    await audio.setMode(SourceMediaSystemUiMode.portraitImmersive);
    await video.setMode(SourceMediaSystemUiMode.portraitImmersive);
    await audio.releaseAndClose();

    expect(platform.calls, <String>['portrait']);

    await video.releaseAndClose();
    expect(platform.calls, <String>['portrait', 'restore']);
  });

  test('landscape request wins until the requesting lease releases', () async {
    final platform = _FakeSystemUiPlatform();
    final coordinator = SourceMediaSystemUiCoordinator.withPlatform(platform);
    final audio = SourceMediaSystemUiLease.withCoordinator(coordinator);
    final video = SourceMediaSystemUiLease.withCoordinator(coordinator);

    await audio.setMode(SourceMediaSystemUiMode.portraitImmersive);
    await video.setMode(SourceMediaSystemUiMode.landscapeImmersive);
    await video.releaseAndClose();
    await audio.releaseAndClose();

    expect(platform.calls, <String>['portrait', 'landscape', 'portrait', 'restore']);
  });

  test('release repairs a partially failed immersive request', () async {
    final platform = _FakeSystemUiPlatform(failPortrait: true);
    final coordinator = SourceMediaSystemUiCoordinator.withPlatform(platform);
    final lease = SourceMediaSystemUiLease.withCoordinator(coordinator);

    await expectLater(lease.setMode(SourceMediaSystemUiMode.portraitImmersive), throwsStateError);
    await lease.releaseAndClose();

    expect(platform.calls, <String>['portrait', 'restore']);
  });

  test('serializes release after an in-flight orientation change', () async {
    final gate = Completer<void>();
    final platform = _FakeSystemUiPlatform(landscapeGate: gate);
    final coordinator = SourceMediaSystemUiCoordinator.withPlatform(platform);
    final lease = SourceMediaSystemUiLease.withCoordinator(coordinator);

    final entering = lease.setMode(SourceMediaSystemUiMode.landscapeImmersive);
    await Future<void>.delayed(Duration.zero);
    final restoring = lease.releaseAndClose();
    expect(platform.calls, <String>['landscape']);

    gate.complete();
    await Future.wait(<Future<void>>[entering, restoring]);

    expect(platform.calls, <String>['landscape', 'restore']);
  });
}

final class _FakeSystemUiPlatform implements SourceMediaSystemUiPlatform {
  _FakeSystemUiPlatform({this.landscapeGate, this.failPortrait = false});

  final Completer<void>? landscapeGate;
  final bool failPortrait;
  final List<String> calls = <String>[];

  @override
  Future<void> enterLandscape() async {
    calls.add('landscape');
    await landscapeGate?.future;
  }

  @override
  Future<void> enterPortrait() async {
    calls.add('portrait');
    if (failPortrait) throw StateError('portrait failed');
  }

  @override
  Future<void> restore() async {
    calls.add('restore');
  }
}
