/// 发现页横向内容的桌面拖动策略。
///
/// 职责：在保留宿主现有滚动设备的前提下，让鼠标也能直接拖动轮播、书架和横向组合。
/// 注意：只扩展设备集合，不改变滚动物理效果、分页吸附或滚轮行为。
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

ScrollBehavior discoveryDragScrollBehavior(BuildContext context) {
  final ScrollBehavior inherited = ScrollConfiguration.of(context);
  return inherited.copyWith(dragDevices: <PointerDeviceKind>{...inherited.dragDevices, PointerDeviceKind.mouse});
}
