import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';
import '../../utils/platform_detector.dart';

class RommWebSurface extends StatefulWidget {
  const RommWebSurface({super.key, required this.url, required this.partition, required this.permits, required this.onError});
  final Uri url;
  final String partition;
  final bool Function(Uri) permits;
  final VoidCallback onError;
  static const channel = MethodChannel('com.plezy/romm_web');
  static Future<bool> available() async {
    if (PlatformDetector.isAppleTV()) return false;
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows) return true;
    try { return await channel.invokeMethod<bool>('available') ?? false; } on MissingPluginException { return false; } on PlatformException { return false; }
  }
  @override State<RommWebSurface> createState() => RommWebSurfaceState();
}
class RommWebSurfaceState extends State<RommWebSurface> {
  InAppWebViewController? _controller;
  bool get _native => !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows);
  final _bounds = GlobalKey();
  final _owner = const Uuid().v4();
  bool _attached = false, _opening = false;
  bool _visible = true;
  Uri? _loadedUrl;
  Rect? _lastBounds;
  Future<void> visible(bool value) async {
    _visible = value;
    if (_native && _attached) await RommWebSurface.channel.invokeMethod<void>('visible', {'owner': _owner, 'value': value ? 1 : 0});
  }
  Future<Object?> evaluate(String source) => _native
      ? RommWebSurface.channel.invokeMethod<Object?>('evaluate', {'owner': _owner, 'script': source})
      : _controller?.evaluateJavascript(source: source) ?? Future.value();
  Future<void> _layout() async {
    if (!mounted || !_native || _opening) return;
    final box = _bounds.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (_attached && rect == _lastBounds && widget.url == _loadedUrl) return;
    _opening = true;
    try {
      final url = widget.url;
      await RommWebSurface.channel.invokeMethod<void>(_attached && _loadedUrl == url ? 'resize' : 'open', {
        'owner': _owner, 'visible': _visible ? 1 : 0,
        'url': widget.url.toString(), 'origin': widget.url.origin, 'partition': sha256.convert(utf8.encode(widget.partition)).toString(),
        'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height,
      });
      if (!mounted) { await RommWebSurface.channel.invokeMethod<void>('close', {'owner': _owner}); return; }
      _attached = true; _lastBounds = rect; _loadedUrl = url;
      await visible(_visible);
    } catch (_) { if (mounted) widget.onError(); }
    finally { _opening = false; }
  }
  @override void deactivate() { if (_native) { visible(false).catchError((_) {}); } super.deactivate(); }
  @override void activate() { super.activate(); if (_native) { visible(true).catchError((_) {}); } }
  @override void didUpdateWidget(RommWebSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _controller = null;
  }
  @override void dispose() { if (_native) { RommWebSurface.channel.invokeMethod<void>('close', {'owner': _owner}).catchError((_) {}); } super.dispose(); }
  @override Widget build(BuildContext context) {
    if (_native) return LayoutBuilder(builder: (context, constraints) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _layout());
      return SizedBox.expand(key: _bounds);
    });
    final expectedUrl = widget.url;
    return InAppWebView(
      key: ValueKey(expectedUrl),
      initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true, allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false, javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false, allowFileAccess: false, allowContentAccess: false,
        useShouldOverrideUrlLoading: true, javaScriptHandlersForMainFrameOnly: true,
        javaScriptBridgeForMainFrameOnly: true, javaScriptBridgeOriginAllowList: {widget.url.origin}),
      onWebViewCreated: (controller) { if (mounted && expectedUrl == widget.url) _controller = controller; },
      shouldOverrideUrlLoading: (_, action) async {
        final uri = Uri.tryParse(action.request.url?.toString() ?? '');
        return uri != null && widget.permits(uri) ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (_, request, error) { if (mounted && expectedUrl == widget.url && request.isForMainFrame == true) widget.onError(); },
      onReceivedHttpError: (_, request, response) { if (mounted && expectedUrl == widget.url && request.isForMainFrame == true) widget.onError(); },
      onPermissionRequest: (_, request) async => PermissionResponse(resources: request.resources, action: PermissionResponseAction.DENY),
    );
  }
}
