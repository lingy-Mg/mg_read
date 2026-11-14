/// 视频缓冲反馈的动效策略回归；不初始化原生后端，不停止实际播放会话。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/src/ui/video_player_buffering_indicator.dart';

void main() {
  testWidgets(
    'buffering becomes static when motion is disabled while keeping waiting detail',
    (tester) async {
      Widget host(bool disabled) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disabled),
          child: const Scaffold(
            body: VideoPlayerBufferingIndicator(buffering: true),
          ),
        ),
      );
      await tester.pumpWidget(host(false));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(host(true));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('网络缓冲中'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(host(false));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
