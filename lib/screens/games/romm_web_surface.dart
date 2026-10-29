import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../utils/platform_detector.dart';

class RommWebSurface extends StatefulWidget {
  const RommWebSurface({super.key, required this.url, required this.permits, required this.onError});
  final Uri url;
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
  bool _attached = false, _opening = false;
  Rect? _lastBounds;
  Future<Object?> evaluate(String source) => _native
      ? RommWebSurface.channel.invokeMethod<Object?>('evaluate', {'script': source})
      : _controller?.evaluateJavascript(source: source) ?? Future.value();
  Future<void> _layout() async {
    if (!mounted || !_native || _opening) return;
    final box = _bounds.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (_attached && rect == _lastBounds) return;
    _opening = true;
    try {
      await RommWebSurface.channel.invokeMethod<void>(_attached ? 'resize' : 'open', {
        'url': widget.url.toString(), 'origin': widget.url.origin,
        'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height,
      });
      _attached = true; _lastBounds = rect;
    } catch (_) { if (mounted) widget.onError(); }
    finally { _opening = false; }
  }
  @override void dispose() { if (_native) { RommWebSurface.channel.invokeMethod<void>('close').catchError((_) {}); } super.dispose(); }
  @override Widget build(BuildContext context) {
    if (_native) return LayoutBuilder(builder: (context, constraints) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _layout());
      return SizedBox.expand(key: _bounds);
    });
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true, allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false, javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false, allowFileAccess: false, allowContentAccess: false,
        useShouldOverrideUrlLoading: true, javaScriptHandlersForMainFrameOnly: true,
        javaScriptBridgeForMainFrameOnly: true, javaScriptBridgeOriginAllowList: {widget.url.origin}),
      onWebViewCreated: (controller) => _controller = controller,
      shouldOverrideUrlLoading: (_, action) async {
        final uri = Uri.tryParse(action.request.url?.toString() ?? '');
        return uri != null && widget.permits(uri) ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (_, request, error) { if (request.isForMainFrame == true) widget.onError(); },
      onPermissionRequest: (_, request) async => PermissionResponse(resources: request.resources, action: PermissionResponseAction.DENY),
    );
  }
}
