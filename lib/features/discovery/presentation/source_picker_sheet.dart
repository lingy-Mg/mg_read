/// Discovery source selection sheet.
///
/// Owns source search, pinning, selection, and the management
/// hand-off. Runtime installation details remain outside this presentation
/// boundary; visual controls and list rows live in focused part files.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

part 'source_picker_sheet_controls.dart';
part 'source_picker_sheet_list.dart';

/// Result returned by the discovery source picker.
sealed class DiscoverySourcePickerResult {
  const DiscoverySourcePickerResult();
}

/// The user selected an enabled source for the discovery page.
final class DiscoverySourceSelected extends DiscoverySourcePickerResult {
  const DiscoverySourceSelected(this.sourceId);

  final String sourceId;
}

/// The search page selected the application-owned all-source scope.
final class DiscoveryAllSourcesSelected extends DiscoverySourcePickerResult {
  const DiscoveryAllSourcesSelected();
}

/// The user requested the Runtime-owned source management surface.
final class DiscoverySourceManagementRequested extends DiscoverySourcePickerResult {
  const DiscoverySourceManagementRequested();
}

enum DiscoverySourceWebViewAction { enterDebug, show }

final class DiscoverySourceWebViewActionRequested extends DiscoverySourcePickerResult {
  const DiscoverySourceWebViewActionRequested({required this.sourceId, required this.action});

  final String sourceId;
  final DiscoverySourceWebViewAction action;
}

/// Shows the discovery source picker without exposing Runtime installation data.
Future<DiscoverySourcePickerResult?> showDiscoverySourcePicker(
  BuildContext context, {
  required List<PluginSourceDescriptor> sources,
  required String? selectedSourceId,
  bool allowAllSources = false,
  Iterable<String> pinnedSourceIds = const <String>[],
  Future<void> Function(String sourceId, bool pinned)? onPinChanged,
}) {
  return showModalBottomSheet<DiscoverySourcePickerResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.38),
    elevation: 0,
    builder: (context) => _DiscoverySourcePickerSheet(
      sources: sources,
      selectedSourceId: selectedSourceId,
      allowAllSources: allowAllSources,
      pinnedSourceIds: pinnedSourceIds,
      onPinChanged: onPinChanged,
    ),
  );
}

class _DiscoverySourcePickerSheet extends StatefulWidget {
  _DiscoverySourcePickerSheet({
    required this.sources,
    required this.selectedSourceId,
    required this.allowAllSources,
    required Iterable<String> pinnedSourceIds,
    this.onPinChanged,
  }) : pinnedSourceIds = List<String>.unmodifiable(pinnedSourceIds);

  final List<PluginSourceDescriptor> sources;
  final String? selectedSourceId;
  final bool allowAllSources;
  final List<String> pinnedSourceIds;
  final Future<void> Function(String sourceId, bool pinned)? onPinChanged;

  @override
  State<_DiscoverySourcePickerSheet> createState() => _DiscoverySourcePickerSheetState();
}

class _DiscoverySourcePickerSheetState extends State<_DiscoverySourcePickerSheet> {
  bool _searchExpanded = false;
  String _query = '';
  late final TextEditingController _searchController;
  late List<String> _pinnedSourceIds;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _pinnedSourceIds = List<String>.of(widget.pinnedSourceIds);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<PluginSourceDescriptor> get _visibleSources {
    final query = _query.trim().toLowerCase();
    final visible = widget.sources.where((source) {
      if (query.isEmpty) return true;
      final description = SourceBranding.description(sourceId: source.id, displayName: source.displayName, value: source.description);
      return source.displayName.toLowerCase().contains(query) || description.toLowerCase().contains(query);
    }).toList();
    final pinOrder = <String, int>{for (var index = 0; index < _pinnedSourceIds.length; index++) _pinnedSourceIds[index]: index};
    return visible..sort((left, right) {
      final leftOrder = pinOrder[left.id];
      final rightOrder = pinOrder[right.id];
      if (leftOrder == null && rightOrder == null) {
        final leftSelected = left.id == widget.selectedSourceId;
        final rightSelected = right.id == widget.selectedSourceId;
        if (leftSelected != rightSelected) return leftSelected ? -1 : 1;
        final nameOrder = left.displayName.toLowerCase().compareTo(right.displayName.toLowerCase());
        return nameOrder == 0 ? left.id.compareTo(right.id) : nameOrder;
      }
      if (leftOrder == null) return 1;
      if (rightOrder == null) return -1;
      return leftOrder.compareTo(rightOrder);
    });
  }

  bool _isPinned(String sourceId) => _pinnedSourceIds.contains(sourceId);

  String get _selectedSourceLabel {
    if (widget.allowAllSources && widget.selectedSourceId == null) return '全部数据源';
    for (final source in widget.sources) {
      if (source.id == widget.selectedSourceId) return source.displayName;
    }
    return '未选择';
  }

  void _clearQuery() {
    _searchController.clear();
    setState(() => _query = '');
  }

  void _toggleSearch() {
    if (_searchExpanded) {
      _clearQuery();
    }
    setState(() => _searchExpanded = !_searchExpanded);
  }

  Future<void> _togglePinned(String sourceId) async {
    final pinned = !_isPinned(sourceId);
    final previous = List<String>.of(_pinnedSourceIds);
    setState(() {
      _pinnedSourceIds.remove(sourceId);
      if (pinned) _pinnedSourceIds.insert(0, sourceId);
    });
    try {
      await widget.onPinChanged?.call(sourceId, pinned);
    } on Object {
      if (!mounted) return;
      setState(() => _pinnedSourceIds = previous);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('置顶状态保存失败，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleSources = _visibleSources.toList(growable: false);
    final tokens = AppThemeTokens.of(context);
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth > 560 ? 520.0 : constraints.maxWidth;
          return Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              key: const Key('discovery-source-picker-panel'),
              width: width,
              height: constraints.maxHeight * 0.86,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: tokens.shadow.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, -6)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Column(
                    children: <Widget>[
                      _SourcePickerHeader(
                        sourceCount: widget.sources.length,
                        selectedSourceLabel: _selectedSourceLabel,
                        searchExpanded: _searchExpanded,
                        query: _query,
                        searchController: _searchController,
                        onToggleSearch: _toggleSearch,
                        onQueryChanged: (value) => setState(() => _query = value),
                        onClearQuery: _clearQuery,
                        onClose: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          children: <Widget>[
                            if (widget.allowAllSources)
                              _AllSourcesPickerRow(
                                selected: widget.selectedSourceId == null,
                                onPressed: () => Navigator.of(context).pop(const DiscoveryAllSourcesSelected()),
                              ),
                            Expanded(
                              child: _SourcePickerList(
                                sources: visibleSources,
                                selectedSourceId: widget.selectedSourceId,
                                pinnedSourceIds: _pinnedSourceIds,
                                query: _query,
                                hasAnySources: widget.sources.isNotEmpty,
                                onClearQuery: _clearQuery,
                                onSourcePressed: (sourceId) => Navigator.of(context).pop(DiscoverySourceSelected(sourceId)),
                                onPinPressed: _togglePinned,
                                onWebViewAction: (sourceId, action) =>
                                    Navigator.of(context).pop(DiscoverySourceWebViewActionRequested(sourceId: sourceId, action: action)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _SourcePickerFooter(
                        onManagePressed: () => Navigator.of(context).pop(const DiscoverySourceManagementRequested()),
                        onAddPressed: () => Navigator.of(context).pop(const DiscoverySourceManagementRequested()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
