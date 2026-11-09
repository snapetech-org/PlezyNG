import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../mixins/refreshable.dart';
import '../../models/seerr/seerr_media.dart';
import '../../models/seerr/seerr_request_item.dart';
import '../../providers/seerr_account_provider.dart';
import '../../services/catalog/seerr_catalog_source.dart';
import '../../services/seerr/seerr_client.dart';
import '../../services/seerr/seerr_constants.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/seerr_request_sheet.dart';

String _categoryLabel(SeerrRequestCategory category) => switch (category) {
  SeerrRequestCategory.movies => t.downloads.movies,
  SeerrRequestCategory.shows => t.downloads.tvShows,
  SeerrRequestCategory.ebooks => t.fileSources.ebooks,
  SeerrRequestCategory.audiobooks => t.fileSources.audiobooks,
};

String _requestItemStatusLabel(SeerrRequestItem item, SeerrClient client) {
  final status = item.status(client.session.product);
  if (status == SeerrMediaStatus.available) return item.is4k ? t.explore.badge.availableIn4k : t.seerr.statusAvailable;
  if (item.requestStatus == 3) return t.explore.badge.declined;
  if (item.requestStatus == 4) return t.explore.badge.requestFailed;
  if (item.requestStatus == 1) return t.explore.badge.pendingApproval;
  if (item.isRequested(client.session.product)) {
    return status == SeerrMediaStatus.processing
        ? t.seerr.statusProcessing
        : item.is4k
        ? t.explore.badge.requested4k
        : t.seerr.statusRequested;
  }
  return switch (status) {
    SeerrMediaStatus.partiallyAvailable => t.seerr.statusPartiallyAvailable,
    SeerrMediaStatus.blocklisted => t.seerr.statusBlocklisted,
    _ => t.seerr.statusNotRequested,
  };
}

/// A profile-bound user request surface. It never exposes administrative actions.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});
  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> with FocusableTab, Refreshable, ManualRefreshable {
  final _discoverFocus = FocusNode(debugLabel: "requests_discover");

  @override
  void focusActiveTabIfReady() {
    if (mounted) _discoverFocus.requestFocus();
  }

  @override
  Future<void> refresh() => _load();

  @override
  void manualRefresh() {
    _load();
  }

  SeerrClient? _client;
  SeerrRequestCategory _category = SeerrRequestCategory.movies;
  bool _discover = false;
  bool _loading = true;
  bool _failed = false;
  bool _hasMore = false;
  int _page = 1;
  int _generation = 0;
  final _search = TextEditingController();
  List<SeerrRequestItem> _items = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = context.watch<SeerrAccountProvider>().catalogClient;
    if (identical(client, _client)) return;
    _client = client;
    _generation++;
    _items = [];
    _search.clear();
    _page = 1;
    _failed = false;
    _loading = client != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    _discoverFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final client = _client;
    if (client == null) return;
    final generation = ++_generation;
    final page = more ? _page + 1 : 1;
    setState(() {
      _loading = true;
      _failed = false;
      if (!more) _items = [];
    });
    try {
      final result = await client.browseRequests(_category, discover: _discover, query: _search.text, page: page);
      if (!mounted || generation != _generation || !identical(client, _client)) return;
      setState(() {
        _items = more ? [..._items, ...result.items] : result.items;
        _page = page;
        _hasMore = result.hasMore;
      });
    } catch (error) {
      appLogger.w('Request overview failed', error: error);
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _open(SeerrRequestItem item) async {
    final client = _client;
    if (client == null) return;
    try {
      final details = await client.requestDetails(item);
      if (!mounted || !identical(_client, client)) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _RequestDetail(client: client, item: details),
      );
      if (mounted && identical(_client, client)) await _load();
    } catch (error) {
      appLogger.w('Request details failed', error: error);
      if (mounted && identical(_client, client)) showErrorSnackBar(context, t.seerr.requestsLoadFailed);
    }
  }

  @override
  Widget build(BuildContext context) => FocusedScrollScaffold(
    title: Text(t.seerr.requests),
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    focusNode: _discoverFocus,
                    label: Text(t.discover.title),
                    selected: _discover,
                    onSelected: (value) {
                      _discover = value;
                      _load();
                    },
                  ),
                  for (final category in SeerrRequestCategory.values)
                    ChoiceChip(
                      label: Text(_categoryLabel(category)),
                      selected: _category == category,
                      onSelected: (_) {
                        _category = category;
                        _load();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FocusableTextField(
                controller: _search,
                maxLength: 200,
                decoration: InputDecoration(labelText: t.common.search),
                onSubmitted: (_) => _load(),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(onPressed: _loading ? null : () => _load(), child: Text(t.common.refresh)),
              ),
              if (_client == null) Text(t.seerr.permissionRevoked),
              if (_loading) const LinearProgressIndicator(),
              if (_failed) Text(t.seerr.requestsLoadFailed),
              if (!_loading && !_failed && _items.isEmpty) Text(t.messages.noResultsFound),
            ],
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = _items[index];
          return FocusableListTile(
            title: Text(item.is4k ? '${item.title} · 4K' : item.title),
            subtitle: Text(_requestItemStatusLabel(item, _client!)),
            onTap: () => _open(item),
          );
        }, childCount: _items.length),
      ),
      if (_hasMore && !_loading)
        SliverToBoxAdapter(
          child: TextButton(onPressed: () => _load(more: true), child: Text(t.fileSources.loadMore)),
        ),
    ],
  );
}

class _RequestDetail extends StatefulWidget {
  final SeerrClient client;
  final SeerrRequestItem item;
  const _RequestDetail({required this.client, required this.item});
  @override
  State<_RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<_RequestDetail> {
  bool _busy = false;
  bool _submitted = false;
  String? _error;
  bool get _current => identical(context.read<SeerrAccountProvider>().catalogClient, widget.client);

  Future<void> _request() async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.item.category.isBook) {
        await widget.client.requestBook(widget.item);
        if (mounted && _current) setState(() => _submitted = true);
      } else {
        await showSeerrRequestSheet(
          context,
          source: SeerrCatalogSource(widget.client),
          kind: widget.item.category == SeerrRequestCategory.movies ? MediaKind.movie : MediaKind.show,
          tmdbId: widget.item.id as int,
          title: widget.item.title,
          minimal: true,
        );
        // Reload authoritative state after season selection/submission or cancellation.
        if (mounted && _current) Navigator.of(context).pop();
      }
    } catch (error) {
      appLogger.w('Basic media request failed', error: error);
      if (mounted && _current) setState(() => _error = t.seerr.requestsLoadFailed);
    } finally {
      if (mounted && _current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SeerrAccountProvider>();
    if (!_current) {
      return AlertDialog(
        title: Text(t.seerr.permissionRevoked),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.close))],
      );
    }
    final item = widget.item;
    final permission = item.category.isBook
        ? SeerrPermission.requestBook
        : item.category == SeerrRequestCategory.movies
        ? SeerrPermission.requestMovie
        : SeerrPermission.requestTv;
    final canRequest =
        _current && seerrHasPermission(widget.client.session.permissions, [SeerrPermission.request, permission]);
    final status = item.status(widget.client.session.product);
    final requestable =
        status != SeerrMediaStatus.available &&
        status != SeerrMediaStatus.blocklisted &&
        (item.category == SeerrRequestCategory.shows || !item.isRequested(widget.client.session.product));
    return AlertDialog(
      title: Text(item.is4k ? '${item.title} · 4K' : item.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_submitted ? t.seerr.requestSubmitted : _requestItemStatusLabel(item, widget.client)),
              if (item.overview.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 16), child: Text(item.overview)),
              if (!_current) Text(t.seerr.permissionRevoked),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.close)),
        TextButton(
          onPressed: !_current
              ? null
              : () async {
                  final url = Uri.parse(
                    '${widget.client.session.baseUrl}/${item.category.mediaType}/${Uri.encodeComponent('${item.id}')}',
                  );
                  try {
                    if (!await launchUrl(url, mode: LaunchMode.externalApplication) && mounted && _current) {
                      setState(() => _error = t.common.error);
                    }
                  } catch (error) {
                    appLogger.w('Request collection link failed', error: error);
                    if (mounted && _current) setState(() => _error = t.common.error);
                  }
                },
          child: Text(t.common.viewAll),
        ),
        if (canRequest && requestable && !item.is4k)
          FilledButton(onPressed: _busy || _submitted ? null : _request, child: Text(t.seerr.request)),
      ],
    );
  }
}
