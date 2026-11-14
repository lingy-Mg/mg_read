/// 防止宿主与独立阅读/播放组件重新绕过共享无动画策略；不扫描第三方或运行时源码。
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('owned UI routes loading, controls, refresh and notices through motion policy', () {
    final bypasses = <String>[];
    final rawWidgets = RegExp(
      r'\b(?:CircularProgressIndicator|LinearProgressIndicator|Switch|SwitchListTile|CheckboxListTile|RefreshIndicator|Slider|Tooltip|Scrollbar|DropdownButton|DropdownButtonFormField|Material|Card|Scaffold|TextField|TextFormField|ChoiceChip|FilterChip|ListTile|Dialog|AlertDialog)(?:<[^>]+>)?(?:\.(?:adaptive|fullscreen))?\(',
    );
    for (final root in [
      'lib',
      'packages/mg_read_reader_ui/lib',
      'packages/mg_read_audio_player/lib',
      'packages/mg_read_video_player/lib',
    ]) {
      for (final file in Directory(root).listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        if (rawWidgets.hasMatch(source) || RegExp(r'\.showSnackBar\(').hasMatch(source)) bypasses.add(file.path);
        final overlays = RegExp(r'\b(?:showDialog|showModalBottomSheet|showBottomSheet)(?:<[^>]+>)?\(').allMatches(source).length;
        if (overlays > RegExp(r'\bmotionOverlayBuilder\(').allMatches(source).length) {
          bypasses.add('${file.path}: overlay must preserve caller motion policy');
        }
      }
    }
    expect(bypasses, isEmpty, reason: 'Use mg_read_motion primitives so no-animation mode has no framework animation leaks.');
  });
}
