/// 阅读器设置面板状态库。
///
/// 职责：
/// - 维护设置面板的页面切换、预览与提交状态。
/// - 将字体、自动阅读、目录和书签动作回调给阅读器会话。
///
/// 注意：
/// - 不在 build() 中加载字体、访问宿主数据或写持久化。
/// - Slider 预览在关闭时只提交最新值，不能破坏设置面板的滚动锁定语义。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/contracts.dart';
import '../../api/models.dart';
import '../../core/auto_reading_coordinator.dart';
import '../../platform/reader_platform.dart';
import '../reader_strings.dart';
import '../reader_theme.dart';
import '../fonts/reader_font_catalog.dart';
import 'reader_settings_controls.dart';
import 'reader_settings_tokens.dart';

part 'reader_settings_coordinator.dart';
part 'reader_settings_entry.dart';
part 'reader_settings_main_sections.dart';
part 'reader_settings_subpage_sections.dart';

const List<double> _fontSizes = <double>[16, 19, 22, 26, 32];
const List<ReaderThemePreset> _themeOrder = <ReaderThemePreset>[
  ReaderThemePreset.day,
  ReaderThemePreset.parchment,
  ReaderThemePreset.eyeCare,
  ReaderThemePreset.mistBlue,
  ReaderThemePreset.night,
  ReaderThemePreset.deepNight,
  ReaderThemePreset.charcoal,
];
