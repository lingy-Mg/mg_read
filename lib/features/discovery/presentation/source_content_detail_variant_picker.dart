/// 内容来源版本选择；TV 使用完整页面，确认后调用原路由切换回调。
/// 不拥有搜索或详情状态，退出和选择当前版本都不会启动新的请求。
library;

import 'package:mg_read/shared/presentation/motion/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';

import 'package:mg_read/features/discovery/application/batch_search.dart';

/// Opens the source-version selector used by the content detail sheet.
Future<void> showSourceContentVariantPicker(
  BuildContext context, {
  required List<SourceSearchHit> variants,
  required String selectedPluginId,
  required String selectedContentId,
  required Future<void> Function(SourceSearchHit variant) onSelected,
}) async {
  final tv = TvModeScope.isEnabled(context);
  final selected = tv
      ? await Navigator.of(context).push<SourceSearchHit>(
          MaterialPageRoute(
            builder: (context) => TvFocusRegion(
              child: Scaffold(
                appBar: AppBar(title: const Text('切换来源')),
                body: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          for (final variant in variants)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: TvFocusable(
                                key: ValueKey('tv-source-variant-${variant.pluginId}-${variant.content.id}'),
                                autofocus: variant.content.id == selectedContentId && variant.pluginId == selectedPluginId,
                                selected: variant.content.id == selectedContentId && variant.pluginId == selectedPluginId,
                                onPressed: () => Navigator.pop(context, variant),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(variant.source.displayName, style: Theme.of(context).textTheme.titleLarge),
                                    const SizedBox(height: 8),
                                    Text(variant.content.title),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
      : await showModalBottomSheet<SourceSearchHit>(
          context: context,
          sheetAnimationStyle: AppMotion.overlayStyle(context),
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: variants.length,
              itemBuilder: (context, index) {
                final variant = variants[index];
                return ListTile(
                  leading: Icon(index == 0 ? Icons.star_rounded : Icons.source_outlined),
                  title: Text(variant.source.displayName),
                  subtitle: Text(variant.content.title),
                  trailing: variant.content.id == selectedContentId && variant.pluginId == selectedPluginId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(context).pop(variant),
                );
              },
            ),
          ),
        );
  if (selected == null || (selected.pluginId == selectedPluginId && selected.content.id == selectedContentId)) return;
  await onSelected(selected);
}
