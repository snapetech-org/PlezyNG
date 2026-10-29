import 'package:flutter/material.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';

class RommLibraryFilters extends StatelessWidget {
  const RommLibraryFilters({super.key, required this.controller, required this.onConnections, required this.onLink});
  final RommController controller;
  final VoidCallback onConnections, onLink;
  @override Widget build(BuildContext context) {
    final c = controller, cap = controller.capabilities[controller.source];
    final lists = c.collections[c.source] ?? <RommCollection>[];
    Future<void> filter({String? source, int? platform, RommCollection? collection}) => c.refresh(
      changeFilter: true, connectionId: source ?? c.source, platform: platform, list: collection).catchError((_) {});
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(onPressed: onConnections, icon: const Icon(Icons.videogame_asset), label: Text(rommText(context, c.connections.isEmpty ? 'connect' : 'connections'))),
        OutlinedButton(onPressed: onLink, child: Text(rommText(context, 'openLink'))),
        if (c.connections.isNotEmpty) ...[
          DropdownButton<String>(value: c.source, items: [DropdownMenuItem(value: '', child: Text(rommText(context, 'allLibraries'))),
            for (final source in c.connections) DropdownMenuItem(value: source.id, child: Text(isolateDisplayText(source.name)))],
            onChanged: c.busy ? null : (value) => filter(source: value)),
          if (cap != null) DropdownButton<int>(value: cap.platforms.any((p) => p['id'] == c.platformId) ? c.platformId : 0,
            items: [DropdownMenuItem(value: 0, child: Text(rommText(context, 'allPlatforms'))),
              for (final platform in cap.platforms) DropdownMenuItem(value: rommInt(platform['id']), child: Text(isolateDisplayText(rommString(platform['display_name'] ?? platform['name'], 100))))],
            onChanged: c.busy ? null : (id) => filter(platform: id == 0 ? null : id, collection: c.collection)),
          if (lists.isNotEmpty) DropdownButton<String>(value: c.collection == null || !lists.any((list) => list.kind == c.collection!.kind && list.id == c.collection!.id) ? '' : '${c.collection!.kind}:${c.collection!.id}',
            items: [DropdownMenuItem(value: '', child: Text(rommText(context, 'allCollections'))),
              for (final list in lists) DropdownMenuItem(value: '${list.kind}:${list.id}', child: Text(isolateDisplayText(list.name)))],
            onChanged: c.busy ? null : (key) => filter(platform: c.platformId, collection: lists.where((l) => '${l.kind}:${l.id}' == key).firstOrNull)),
          IconButton(onPressed: c.busy ? null : () => c.refresh(), tooltip: rommText(context, 'refresh'), icon: const Icon(Icons.refresh)),
          if (c.hasMore) OutlinedButton(onPressed: c.busy ? null : () => c.refresh(more: true), child: Text(rommText(context, 'more'))),
        ],
      ]),
      if (c.busy) const LinearProgressIndicator(),
      for (final error in c.errors.entries) Padding(padding: const EdgeInsets.only(top: 8), child: Text(
        '${isolateDisplayText(c.connection(error.key).name)}: ${rommText(context, error.value)} ${rommText(context, 'cached')}',
        semanticsLabel: rommText(context, error.value))),
    ]));
  }
}
