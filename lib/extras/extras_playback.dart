import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../i18n/strings.g.dart';
import '../utils/platform_detector.dart';
import '../utils/video_player_navigation.dart';
import '../widgets/app_icon.dart';
import 'extras_models.dart';
import 'extras_youtube_player.dart';
import 'extras_session.dart';

/// Provider media is never resolved to a raw stream or sent through the native
/// movie player. Handoff progress means opened, not completed.
Future<void> playExtra(BuildContext context, ExtrasSession session, ExtraEntry entry, {int? seconds}) async {
  if (!session.allows(entry)) return;
  final native = session.nativeItem(entry);
  if (native != null) {
    try {
      await session.store.recordProgress(entry.id, seconds: seconds);
    } catch (_) {
      /* Playback does not require saved progress. */
    }
    if (!context.mounted || !session.allows(entry)) return;
    await navigateToVideoPlayer(
      context,
      metadata: native,
      isOffline: session.subject.offline,
      initialPosition: seconds == null ? null : Duration(seconds: seconds),
      skipCinemaExtras: true,
      skipPreroll: true,
      isLaunchCurrent: () => session.allows(entry),
    );
    return;
  }
  if (!session.externalPermitted || session.subject.offline || canonicalExtraUrl(entry.url) == null) return;
  if (!context.mounted || !session.allows(entry)) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ExtraPlaybackScreen(session: session, entry: entry, start: seconds),
    ),
  );
}

class ExtraPlaybackScreen extends StatefulWidget {
  const ExtraPlaybackScreen({super.key, required this.session, required this.entry, this.start});
  final ExtrasSession session;
  final ExtraEntry entry;
  final int? start;
  @override
  State<ExtraPlaybackScreen> createState() => _ExtraPlaybackScreenState();
}

class _ExtraPlaybackScreenState extends State<ExtraPlaybackScreen> with WidgetsBindingObserver {
  InAppWebViewController? _web;
  Timer? _startupTimer;
  bool _embedded = false, _failed = false;
  int _position = 0, _lastSaved = -10;
  bool get _canEmbed =>
      !kIsWeb &&
      !PlatformDetector.isTV() &&
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform) &&
      widget.entry.url?.host == 'www.youtube.com';
  Uri get _watchUrl {
    final uri = canonicalExtraUrl(widget.entry.url)!;
    final start = _position;
    if (start <= 0) return uri;
    return uri.host == 'vimeo.com'
        ? uri.replace(fragment: 't=${start}s')
        : uri.replace(queryParameters: {...uri.queryParameters, 't': '${start}s'});
  }

  @override
  void initState() {
    super.initState();
    _position = widget.start ?? 0;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
    unawaited(_load());
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (!widget.session.allows(widget.entry)) {
      _startupTimer?.cancel();
      _web = null;
    }
    setState(() {
      if (!widget.session.allows(widget.entry)) _embedded = false;
    });
  }

  void _startEmbed() {
    if (!widget.session.allows(widget.entry)) return;
    _startupTimer?.cancel();
    _startupTimer = Timer(const Duration(seconds: 15), _failEmbed);
    setState(() => _embedded = true);
  }

  void _failEmbed() {
    _startupTimer?.cancel();
    _web = null;
    if (mounted) setState(() => _failed = true);
  }

  Future<void> _load() async {
    Map<String, dynamic> progress = {};
    try {
      progress = await widget.session.store.progress(widget.entry.id);
    } catch (_) {
      /* Playback does not require saved progress. */
    }
    if (mounted && !_embedded) setState(() => _position = widget.start ?? (progress['seconds'] as int? ?? 0));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(
        _web?.evaluateJavascript(source: 'if(window.player) player.pauseVideo();').catchError((Object _) => null),
      );
    }
  }

  Future<void> _open() async {
    if (!widget.session.allows(widget.entry)) return;
    var launched = false;
    try {
      launched = await launchUrl(_watchUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* QR remains available */
    }
    if (launched) {
      _startupTimer?.cancel();
      _web = null;
      try {
        await widget.session.store.recordProgress(widget.entry.id);
      } catch (_) {
        /* Handoff already succeeded. */
      }
    }
    if (mounted) {
      setState(() {
        _failed = !launched;
        if (launched) _embedded = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant ExtraPlaybackScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_sessionChanged);
      widget.session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_sessionChanged);
    _startupTimer?.cancel();
    super.dispose();
  }

  Widget _embeddedPlayer() {
    try {
      return InAppWebView(
        initialData: InAppWebViewInitialData(
          data: extraYoutubePlayerHtml(widget.entry.url!.queryParameters['v']!, _position),
          baseUrl: WebUri('https://pleazyng.app/'),
          historyUrl: WebUri('https://pleazyng.app/'),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          allowsInlineMediaPlayback: true,
          mediaPlaybackRequiresUserGesture: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          allowFileAccess: false,
          allowContentAccess: false,
          useShouldOverrideUrlLoading: true,
          javaScriptHandlersForMainFrameOnly: true,
          javaScriptBridgeForMainFrameOnly: true,
          javaScriptBridgeOriginAllowList: {'https://pleazyng.app'},
        ),
        onWebViewCreated: (controller) {
          _web = controller;
          controller.addJavaScriptHandler(
            handlerName: 'extras',
            callback: (arguments) async {
              if (!mounted) return null;
              if (!widget.session.allows(widget.entry)) {
                _sessionChanged();
                return null;
              }
              if (arguments.length != 2 || arguments[1] is! num) return null;
              final rawValue = arguments[1] as num;
              if (!rawValue.isFinite) return null;
              final kind = arguments[0], value = rawValue.toInt();
              if (kind == 'ready') {
                _startupTimer?.cancel();
                return null;
              }
              if (kind == 'error') {
                _failEmbed();
                return null;
              }
              if (value < 0 || value > 86400 || (kind != 'position' && kind != 'ended')) return null;
              _position = value;
              if (kind == 'ended') {
                _startupTimer?.cancel();
                _web = null;
                setState(() => _embedded = false);
              }
              if (kind == 'ended' || (_position - _lastSaved).abs() >= 10) {
                _lastSaved = _position;
                try {
                  await widget.session.store.recordProgress(
                    widget.entry.id,
                    seconds: _position,
                    completed: kind == 'ended',
                  );
                } catch (_) {
                  /* Player remains usable without persistence. */
                }
              }
              return null;
            },
          );
        },
        shouldOverrideUrlLoading: (_, action) async {
          if (action.isForMainFrame != true) return NavigationActionPolicy.ALLOW;
          final uri = Uri.tryParse(action.request.url?.toString() ?? '');
          return uri?.scheme == 'https' && uri?.host == 'pleazyng.app' && uri?.port == 443
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onReceivedError: (_, request, _) {
          if (request.isForMainFrame == true) _failEmbed();
        },
        onReceivedHttpError: (_, request, _) {
          if (request.isForMainFrame == true) _failEmbed();
        },
        onPermissionRequest: (_, request) async =>
            PermissionResponse(resources: request.resources, action: PermissionResponseAction.DENY),
      );
    } catch (_) {
      // Missing native WebView implementations must retain the handoff route.
      WidgetsBinding.instance.addPostFrameCallback((_) => _failEmbed());
      return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.entry.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
    body: SafeArea(
      child: !widget.session.allows(widget.entry)
          ? Center(child: Text(t.bonusExtras.playbackBlocked, textAlign: TextAlign.center))
          : _embedded && !_failed
          ? Column(
              children: [
                Expanded(child: _embeddedPlayer()),
                TextButton(onPressed: _open, child: Text(t.bonusExtras.openProvider)),
              ],
            )
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _failed ? t.bonusExtras.playbackUnavailable : t.bonusExtras.providerNotice,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      if (_canEmbed && !_failed)
                        FilledButton.icon(
                          onPressed: _startEmbed,
                          icon: const AppIcon(Symbols.play_arrow_rounded),
                          label: Text(t.bonusExtras.watchHere),
                        ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(onPressed: _open, child: Text(t.bonusExtras.openProvider)),
                      const SizedBox(height: 20),
                      Text(t.bonusExtras.sendToPhone),
                      const SizedBox(height: 12),
                      Semantics(
                        label: t.bonusExtras.sendToPhone,
                        image: true,
                        child: ColoredBox(
                          color: Colors.white,
                          child: QrImageView(data: _watchUrl.toString(), size: 200, padding: const EdgeInsets.all(12)),
                        ),
                      ),
                      if (!PlatformDetector.isAppleTV())
                        TextButton(
                          onPressed: () async {
                            if (!widget.session.allows(widget.entry)) return;
                            await Clipboard.setData(ClipboardData(text: _watchUrl.toString()));
                          },
                          child: Text(t.bonusExtras.copyLink),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    ),
  );
}
