import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../sources/podcast_directory.dart';
import '../../sources/podcast_library.dart';
import '../../sources/source_controller.dart';
import '../../sources/source_models.dart';
import '../../sources/source_transport.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'add_source_screen.dart';
import 'source_widgets.dart';

class PodcastDiscoverScreen extends StatefulWidget {
  const PodcastDiscoverScreen({super.key});
  @override
  State<PodcastDiscoverScreen> createState() => _PodcastDiscoverScreenState();
}

class _PodcastDiscoverScreenState extends State<PodcastDiscoverScreen> {
  final _search = TextEditingController();
  final _countryInput = TextEditingController(text: 'US');
  PodcastDirectory _directory = PodcastDirectory(SourceTransport());
  SourceController? _sources;
  int? _epoch;
  String _country = 'US', _apiKey = '', _apiSecret = '';
  PodcastDirectoryProvider _provider = PodcastDirectoryProvider.apple;
  List<PodcastDirectoryResult> _results = const [];
  final Set<String> _subscribed = {};
  bool _busy = false, _searched = false;
  int _request = 0;
  int _credentialsRevision = 0;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sources = context.watch<SourceController>();
    if (!identical(_sources, sources) || _epoch != sources.generation) {
      _sources = sources;
      _epoch = sources.generation;
      _request++;
      _credentialsRevision++;
      _directory.close();
      _directory = PodcastDirectory(SourceTransport());
      _apiKey = _apiSecret = '';
      _provider = PodcastDirectoryProvider.apple;
      _results = const [];
      _subscribed.clear();
      _search.clear();
      _busy = false;
      _searched = false;
      _error = null;
      _country = PodcastDirectory.countryCode(Localizations.localeOf(context).countryCode);
      _countryInput.text = _country;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
    }
  }

  Future<void> _loadSettings() async {
    final sources = _sources!, epoch = sources.generation;
    final revision = _credentialsRevision;
    try {
      await sources.ready;
      sources.requireSession(epoch);
      final saved = await sources.repository.privatePreference(sources.profileId!, PodcastLibrary.indexCredentialsKey);
      sources.requireSession(epoch);
      if (!mounted || _epoch != epoch || revision != _credentialsRevision) return;
      setState(() { _apiKey = saved['key'] as String? ?? ''; _apiSecret = saved['secret'] as String? ?? ''; });
    } on Object {
      // Optional directory credentials must not block keyless discovery.
    }
  }

  Future<void> _searchDirectory({bool trending = false}) async {
    if (_busy) return;
    final sources = _sources!, epoch = sources.generation, request = ++_request;
    sources.requireSession(epoch);
    final text = _search.text.trim();
    final uri = Uri.tryParse(text);
    if (!trending && PodcastDirectory.looksLikeUrl(text) &&
        (uri == null || (PodcastDirectory.appleId(uri) == null && PodcastDirectory.indexId(uri) == null))) {
      if (uri == null) {
        setState(() => _error = const SourceException(SourceFailure.invalidData));
        return;
      }
      if (uri.scheme != 'https' && uri.scheme != 'http') {
        setState(() => _error = const SourceException(SourceFailure.unsupported));
        return;
      }
      // A pasted private feed goes straight to the source form, never to a
      // directory. The user explicitly connects it using the existing flow.
      await Navigator.push(context, MaterialPageRoute(builder: (_) =>
          AddSourceScreen(initialKind: FileSourceKind.podcastRss, initialEndpoint: text)));
      return;
    }
    setState(() { _busy = true; _error = null; _searched = true; _results = const []; });
    try {
      final result = await _directory.search(text, provider: _provider, country: _country,
          apiKey: _apiKey, apiSecret: _apiSecret, trending: trending);
      sources.requireSession(epoch);
      if (mounted && request == _request) setState(() => _results = result);
    } catch (error) {
      if (mounted && request == _request && sources.current(epoch)) setState(() => _error = error);
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _subscribe(PodcastDirectoryResult result) async {
    if (_busy) return;
    final sources = _sources!, epoch = sources.generation, request = ++_request;
    setState(() { _busy = true; _error = null; });
    try {
      final count = await PodcastLibrary(sources).subscribe(result.subscription);
      sources.requireSession(epoch);
      if (!mounted || request != _request) return;
      setState(() => _subscribed.add(result.feed.toString()));
      showSnackBar(context, count == 0 ? t.podcasts.alreadySubscribed : t.podcasts.feedAdded);
    } catch (error) {
      if (mounted && request == _request && sources.current(epoch)) setState(() => _error = error);
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _settings() async {
    final sources = _sources!, epoch = sources.generation;
    final key = TextEditingController(text: _apiKey), secret = TextEditingController(text: _apiSecret);
    try {
      final action = await showScopedDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: Text(t.podcasts.indexSetup),
        content: SingleChildScrollView(child: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.podcasts.indexHelp), const SizedBox(height: 16),
            FocusableTextField(controller: key, obscureText: true, autocorrect: false,
              decoration: InputDecoration(labelText: t.podcasts.indexKey)),
            const SizedBox(height: 12),
            FocusableTextField(controller: secret, obscureText: true, autocorrect: false,
              decoration: InputDecoration(labelText: t.podcasts.indexSecret)),
          ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, 'clear'), child: Text(t.common.disconnect)),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(t.common.save))],
      ));
      if (action == null) return;
      sources.requireSession(epoch);
      _credentialsRevision++;
      final nextKey = action == 'clear' ? '' : key.text.trim(), nextSecret = action == 'clear' ? '' : secret.text.trim();
      if (action == 'save' && (nextKey.isEmpty || nextSecret.isEmpty || nextKey.length > 1024 ||
          nextSecret.length > 2048 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(nextKey + nextSecret))) {
        throw const SourceException(SourceFailure.invalidData);
      }
      if (action == 'clear') {
        await sources.repository.forgetPreference(sources.profileId!, PodcastLibrary.indexCredentialsKey);
      } else {
        await sources.repository.savePrivatePreference(sources.profileId!, PodcastLibrary.indexCredentialsKey,
            {'key': nextKey, 'secret': nextSecret});
      }
      sources.requireSession(epoch);
      if (!mounted) return;
      _directory.close();
      _directory = PodcastDirectory(SourceTransport());
      setState(() { _apiKey = nextKey; _apiSecret = nextSecret; _results = const []; _searched = false; });
    } finally { key.dispose(); secret.dispose(); }
  }

  @override
  void dispose() { _request++; _directory.close(); _search.dispose(); _countryInput.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FocusedScrollScaffold(
    title: Text(t.podcasts.discover), focusableAppBarActions: true,
    actions: [IconButton(tooltip: t.podcasts.indexSetup, onPressed: _busy ? null : () => sourceAction(context, _settings),
      icon: const AppIcon(Symbols.settings_rounded))],
    slivers: [SliverPadding(padding: const EdgeInsets.all(24), sliver: SliverToBoxAdapter(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.podcasts.searchHelp), const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final provider in PodcastDirectoryProvider.values)
            ChoiceChip(label: Text(provider == PodcastDirectoryProvider.apple ? 'Apple Podcasts' : 'Podcast Index'),
              selected: _provider == provider, onSelected: _busy ? null : (_) => setState(() {
                _provider = provider; _results = const []; _searched = false; _error = null;
              })),
          OutlinedButton.icon(onPressed: _busy ? null : () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) =>
                const AddSourceScreen(initialKind: FileSourceKind.podcastRss)));
          }, icon: const AppIcon(Symbols.rss_feed_rounded), label: Text(t.podcasts.addFeed)),
        ]),
        const SizedBox(height: 16),
        FocusableTextField(controller: _search, decoration: InputDecoration(labelText: t.podcasts.searchHint),
          onSubmitted: (_) => sourceAction(context, _searchDirectory)),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(onPressed: _busy ? null : () => sourceAction(context, _searchDirectory),
            icon: const AppIcon(Symbols.search_rounded), label: Text(t.common.search)),
          if (_provider == PodcastDirectoryProvider.podcastIndex)
            OutlinedButton(onPressed: _busy ? null : () => sourceAction(context, () => _searchDirectory(trending: true)),
              child: Text(t.podcasts.trending)),
          SizedBox(width: 180, child: FocusableTextField(controller: _countryInput, maxLength: 2,
            decoration: InputDecoration(labelText: t.podcasts.country),
            onChanged: (value) => _country = PodcastDirectory.countryCode(value))),
        ]),
        if (_provider == PodcastDirectoryProvider.podcastIndex && (_apiKey.isEmpty || _apiSecret.isEmpty))
          Padding(padding: const EdgeInsets.only(top: 16), child: Text(t.podcasts.indexHelp)),
        if (_busy) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: LinearProgressIndicator()),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
          child: SourceErrorMessage(message: _error is SourceException && (_error as SourceException).status == 429
              ? t.podcasts.rateLimited : sourceFailureText(_error!))),
        if (!_busy && _searched && _error == null && _results.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(t.podcasts.noResults)),
      ]))),
      SliverPadding(padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 24),
        sliver: SliverList.builder(itemCount: _results.length, itemBuilder: (context, index) {
          final item = _results[index], subscribed = _subscribed.contains(_results[index].feed.toString());
          return SourceTile(title: item.title, subtitle: item.author, icon: Symbols.podcasts_rounded,
            index: index, count: _results.length,
            onTap: _busy || subscribed ? null : () => _subscribe(item),
            trailing: Wrap(spacing: 4, children: [
              if (item.website != null) IconButton(tooltip: t.podcasts.directoryLink,
                onPressed: () => sourceAction(context, () async {
                  if (!await launchUrl(item.website!, mode: LaunchMode.externalApplication)) {
                    throw const SourceException(SourceFailure.unavailable);
                  }
                }), icon: const AppIcon(Symbols.open_in_new_rounded)),
              IconButton(tooltip: subscribed ? t.podcasts.subscribed : t.podcasts.subscribe,
                onPressed: _busy || subscribed ? null : () => _subscribe(item),
                icon: AppIcon(subscribed ? Symbols.check_rounded : Symbols.add_rounded)),
            ]));
        })),
    ],
  );
}
