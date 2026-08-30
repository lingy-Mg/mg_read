/// 发现页数据源语义图标映射。
///
/// 职责：把 Plugin API 的稳定语义图标名映射为宿主 Material 图标，供发现页多种组件复用。
/// 注意：数据源不能传 IconData、字体码点、颜色或尺寸；未知图标会在 Runtime 边界被拒绝。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

IconData discoverySemanticIcon(PluginDiscoveryIcon? icon, {IconData fallback = Icons.category_rounded}) => switch (icon) {
  null => fallback,
  PluginDiscoveryIcon.allTimeRanking => Icons.emoji_events_rounded,
  PluginDiscoveryIcon.audio => Icons.headphones_rounded,
  PluginDiscoveryIcon.book => Icons.menu_book_rounded,
  PluginDiscoveryIcon.books => Icons.auto_stories_rounded,
  PluginDiscoveryIcon.category => Icons.category_rounded,
  PluginDiscoveryIcon.classic => Icons.local_library_rounded,
  PluginDiscoveryIcon.completed => Icons.task_alt_rounded,
  PluginDiscoveryIcon.dailyRanking => Icons.today_rounded,
  PluginDiscoveryIcon.explore => Icons.explore_rounded,
  PluginDiscoveryIcon.fanFiction => Icons.groups_rounded,
  PluginDiscoveryIcon.fantasy => Icons.auto_awesome_rounded,
  PluginDiscoveryIcon.free => Icons.redeem_rounded,
  PluginDiscoveryIcon.game => Icons.sports_esports_rounded,
  PluginDiscoveryIcon.globe => Icons.public_rounded,
  PluginDiscoveryIcon.history => Icons.account_balance_rounded,
  PluginDiscoveryIcon.horror => Icons.dark_mode_rounded,
  PluginDiscoveryIcon.hot => Icons.local_fire_department_rounded,
  PluginDiscoveryIcon.lightNovel => Icons.lightbulb_rounded,
  PluginDiscoveryIcon.manga => Icons.collections_bookmark_rounded,
  PluginDiscoveryIcon.military => Icons.shield_rounded,
  PluginDiscoveryIcon.monthlyRanking => Icons.calendar_month_rounded,
  PluginDiscoveryIcon.mystery => Icons.saved_search_rounded,
  PluginDiscoveryIcon.newRelease => Icons.new_releases_rounded,
  PluginDiscoveryIcon.ongoing => Icons.update_rounded,
  PluginDiscoveryIcon.other => Icons.more_horiz_rounded,
  PluginDiscoveryIcon.ranking => Icons.leaderboard_rounded,
  PluginDiscoveryIcon.recommendation => Icons.recommend_rounded,
  PluginDiscoveryIcon.romance => Icons.favorite_rounded,
  PluginDiscoveryIcon.rural => Icons.agriculture_rounded,
  PluginDiscoveryIcon.school => Icons.school_rounded,
  PluginDiscoveryIcon.scienceFiction => Icons.rocket_launch_rounded,
  PluginDiscoveryIcon.sports => Icons.sports_basketball_rounded,
  PluginDiscoveryIcon.star => Icons.stars_rounded,
  PluginDiscoveryIcon.system => Icons.settings_suggest_rounded,
  PluginDiscoveryIcon.timeTravel => Icons.history_rounded,
  PluginDiscoveryIcon.trending => Icons.trending_up_rounded,
  PluginDiscoveryIcon.urban => Icons.location_city_rounded,
  PluginDiscoveryIcon.video => Icons.movie_rounded,
  PluginDiscoveryIcon.weeklyRanking => Icons.date_range_rounded,
  PluginDiscoveryIcon.wuxia => Icons.sports_martial_arts_rounded,
};
