/// TV discovery is a source chooser. Selecting a source updates the outer
/// navigation while keeping this chooser mounted and its remote focus stable.
library;

import 'package:flutter/material.dart';
import '../application/discovery_page_state.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

class TvDiscoverySourcesPage extends StatelessWidget {
  const TvDiscoverySourcesPage({
    required this.state,
    required this.onSelected,
    required this.onDestinationRequested,
    required this.onRefresh,
    this.onManage,
    super.key,
  });
  final DiscoveryPageState state;
  final ValueChanged<String> onSelected;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final VoidCallback onRefresh;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) => TvFocusRegion(
    child: Scaffold(
      key: const Key('tv-discovery-sources'),
      appBar: AppBottomNavigation(selected: AppNavigationDestination.discover, onSelected: onDestinationRequested),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(28),
          children: [
            Text('选择数据源', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 16),
            if (state.status == DiscoveryPageStatus.loadingSources || state.status == DiscoveryPageStatus.loadingContent)
              const LinearProgressIndicator(),
            if (state.error != null) ...[const Text('数据源加载失败，请重试。'), TvFocusable(onPressed: onRefresh, child: const Text('重试'))],
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 300).floor().clamp(1, 6);
                final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final source in state.sources)
                      SizedBox(
                        width: width,
                        child: TvFocusable(
                          key: ValueKey('tv-source-choice-${source.id}'),
                          selected: source.id == state.selectedSourceId,
                          onPressed: () => onSelected(source.id),
                          child: Row(
                            children: [
                              Icon(source.id == state.selectedSourceId ? Icons.check_circle_rounded : Icons.extension_outlined),
                              const SizedBox(width: 12),
                              Expanded(child: Text(source.displayName, style: Theme.of(context).textTheme.titleLarge)),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (onManage != null) ...[
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TvFocusable(onPressed: onManage, child: const Text('管理数据源')),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
