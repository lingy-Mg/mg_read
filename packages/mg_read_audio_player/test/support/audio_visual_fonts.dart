/// Load repository-local CJK and Material fonts for readable visual baselines.
/// This is test-only fixture I/O; production audio has no reader dependency.
library;

import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadAudioVisualFonts() async {
  final font = <File>[
    File('../mg_read_reader_ui/assets/fonts/MiSansVF.ttf'),
    File('packages/mg_read_reader_ui/assets/fonts/MiSansVF.ttf'),
  ].firstWhere((file) => file.existsSync());
  await (FontLoader(
    'Roboto',
  )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}
