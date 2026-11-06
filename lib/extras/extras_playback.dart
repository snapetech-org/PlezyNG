import 'dart:async';
import 'dart:io';
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
  if (!session.active) return;
  final native = session.nativeItem(entry);
  if (native != null) {
    await session.store.recordProgress(entry.id, seconds: seconds);
    if (!context.mounted || !session.active) return;
    await navigateToVideoPlayer(
      context,
      metadata: native,
      isOffline: session.subject.offline,
      initialPosition: seconds == null ? null : Duration(seconds: seconds),
      skipCinemaExtras: true,
      skipPreroll: true,
      isLaunchCurrent: () => session.active,
    );
    return;
  }
  if (!session.externalPermitted || session.subject.offline || canonicalExtraUrl(entry.url) == null) return;
  if (!context.mounted || !session.active) return;
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
  bool _embedded = false, _failed = false;
  int _position = 0, _lastSaved = -10;
  bool get _canEmbed =>
      !kIsWeb &&
      !PlatformDetector.isTV() &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows) &&
      widget.entry.url?.host == 'www.youtube.com';
  Uri get _watchUrl {
    final uri = canonicalExtraUrl(widget.entry.url)!;
    final start = widget.start ?? _position;
    if (start <= 0) return uri;
    return uri.host == 'vimeo.com'
        ? uri.replace(fragment: 't=${start}s')
        : uri.replace(queryParameters: {...uri.queryParameters, 't': '${start}s'});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    Map<String, dynamic> progress = {};
    try {
      progress = await widget.session.store.progress(widget.entry.id);
    } catch (_) {
      /* Playback does not require saved progress. */
    }
    if (mounted) setState(() => _position = widget.start ?? (progress['seconds'] as int? ?? 0));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_web?.evaluateJavascript(source: 'if(window.player) player.pauseVideo();'));
    }
  }

  Future<void> _open() async {
    if (!widget.session.externalPermitted) return;
    var launched = false;
    try {
      launched = await launchUrl(_watchUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* QR remains available */
    }
    if (launched) {
      try {
        await widget.session.store.recordProgress(widget.entry.id);
      } catch (_) {
        /* Handoff already succeeded. */
      }
    }
    if (mounted) setState(() => _failed = !launched);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.entry.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
    body: SafeArea(
      child: _embedded && !_failed
          ? Column(
              children: [
                Expanded(
                  child: InAppWebView(
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
                          if (!widget.session.externalPermitted) {
                            setState(() => _embedded = false);
                            return null;
                          }
                          if (arguments.length != 2 || arguments[1] is! num) return null;
                          final kind = arguments[0], value = (arguments[1] as num).toInt();
                          if (kind == 'error') {
                            setState(() => _failed = true);
                            return null;
                          }
                          if (value < 0 || value > 86400 || (kind != 'position' && kind != 'ended')) return null;
                          _position = value;
                          if (kind == 'ended') setState(() => _embedded = false);
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
                      if (mounted && request.isForMainFrame == true) setState(() => _failed = true);
                    },
                    onReceivedHttpError: (_, request, _) {
                      if (mounted && request.isForMainFrame == true) setState(() => _failed = true);
                    },
                    onPermissionRequest: (_, request) async =>
                        PermissionResponse(resources: request.resources, action: PermissionResponseAction.DENY),
                  ),
                ),
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
                          onPressed: () => setState(() => _embedded = true),
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
