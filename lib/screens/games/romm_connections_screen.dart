import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../../focus/focusable_text_field.dart';
import '../../games/romm/romm_client.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../utils/snackbar_helper.dart';

class RommConnectionsScreen extends StatelessWidget {
  const RommConnectionsScreen({super.key, required this.controller});
  final RommController controller;
  Future<void> _connect(BuildContext context, [RommConnection? source]) => showDialog<void>(
    context: context, builder: (_) => RommPairDialog(controller: controller, source: source));
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) => FocusedScrollScaffold(
    title: Text(rommText(context, 'connections')),
    slivers: [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(rommText(context, 'connectionHelp')), const SizedBox(height: 16),
        FilledButton.icon(onPressed: controller.current ? () => _connect(context) : null,
          icon: const Icon(Icons.add), label: Text(rommText(context, 'connect'))),
      ]))),
      for (final source in controller.connections) SliverToBoxAdapter(child: FocusableListTile(
        title: Text(isolateDisplayText(source.name)),
        subtitle: Text('${isolateDisplayText(source.username)} · ${source.base.host}\n'
          '${controller.sessionOnly(source.id) ? rommText(context, 'sessionOnly') : source.version}'),
        onTap: () => _connect(context, source),
        trailing: IconButton(tooltip: rommText(context, 'remove'), icon: const Icon(Icons.link_off), onPressed: () async {
          final remove = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
            title: Text(rommText(dialog, 'remove')), content: Text(rommText(dialog, 'removeHelp')),
            actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(rommText(dialog, 'cancel'))),
              FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, 'remove')))]));
          if (remove == true && controller.current) {
            try { await controller.disconnect(source.id); }
            catch (error) { if (context.mounted && controller.current) showErrorSnackBar(context, rommText(context, error is RommFailure ? error.code : 'connectionFailed')); }
          }
        }),
      )),
    ],
  ));
}

class RommPairDialog extends StatefulWidget {
  const RommPairDialog({super.key, required this.controller, this.source});
  final RommController controller;
  final RommConnection? source;
  @override State<RommPairDialog> createState() => _RommPairDialogState();
}
class _RommPairDialogState extends State<RommPairDialog> {
  late final _address = TextEditingController(text: widget.source?.baseUrl ?? 'https://');
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  final _token = TextEditingController();
  RommClient? _pairClient;
  Timer? _poll;
  DateTime? _expires;
  Uri? _verification;
  String _code = '', _deviceCode = '', _error = '';
  int _interval = 5, _generation = 0;
  bool _manual = false, _busy = false, _polling = false;
  @override void initState() { super.initState(); widget.controller.addListener(_profileChanged); }
  void _profileChanged() {
    if (widget.controller.current) return;
    _generation++; _poll?.cancel(); _pairClient?.close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context); if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }
  bool _live(int epoch) => mounted && epoch == _generation && widget.controller.current;
  Future<void> _start() async {
    if (_busy) return;
    _poll?.cancel(); _pairClient?.close(); _verification = null; _code = '';
    final epoch = ++_generation;
    setState(() { _busy = true; _error = ''; });
    try {
      final base = rommBaseUri(_address.text);
      if (_manual) {
        await widget.controller.connect(name: _name.text, base: base, token: _token.text.trim(), replaceId: widget.source?.id, allowed: () => _live(epoch));
        if (_live(epoch)) Navigator.pop(context);
      } else {
        final api = _pairClient = RommClient(base);
        final result = await api.startPairing(const Uuid().v4(), _name.text.trim().isEmpty ? 'PlezyNG' : _name.text.trim());
        if (!_live(epoch)) return;
        _deviceCode = rommString(result['device_code'], 128);
        _code = rommString(result['user_code'], 32);
        _verification = api.resource(rommString(result['verification_path_complete'], 2048));
        _interval = rommInt(result['interval'], 5).clamp(5, 60);
        _expires = DateTime.now().add(Duration(seconds: rommInt(result['expires_in'], 300).clamp(30, 900)));
        if (_deviceCode.isEmpty || _code.isEmpty) throw const RommFailure('romm.invalidResponse');
        setState(() {});
        _schedule(epoch);
      }
    } catch (error) {
      if (_live(epoch)) setState(() { _error = error is RommFailure ? error.code : error is FormatException ? error.message : 'romm.connectionFailed'; _busy = false; });
    }
  }
  void _schedule(int epoch) { _poll = Timer(Duration(seconds: _interval), () => unawaited(_pollToken(epoch))); }
  Future<void> _pollToken(int epoch) async {
    if (!_live(epoch) || _polling) return;
    if (_expires == null || DateTime.now().isAfter(_expires!)) {
      setState(() { _busy = false; _error = 'expired_token'; }); return;
    }
    _polling = true;
    try {
      final grant = await _pairClient!.pollPairing(_deviceCode);
      if (!_live(epoch)) return;
      await widget.controller.connect(name: _name.text, base: _pairClient!.base,
        token: rommString(grant['access_token'], 4096), deviceId: rommString(grant['device_id'], 128),
        scopes: rommStrings(grant['scopes']), replaceId: widget.source?.id, allowed: () => _live(epoch));
      if (_live(epoch)) Navigator.pop(context);
    } on RommFailure catch (error) {
      if (!_live(epoch)) return;
      if (error.code == 'authorization_pending' || error.code == 'slow_down') {
        if (error.code == 'slow_down') _interval = (_interval + 5).clamp(5, 60);
        _schedule(epoch);
      } else { setState(() { _error = error.code; _busy = false; }); }
    } catch (_) { if (_live(epoch)) setState(() { _error = 'romm.connectionFailed'; _busy = false; }); }
    finally { _polling = false; }
  }
  @override void dispose() {
    widget.controller.removeListener(_profileChanged);
    _generation++; _poll?.cancel(); _pairClient?.close();
    _address.dispose(); _name.dispose(); _token.dispose(); super.dispose();
  }
  @override Widget build(BuildContext context) => AlertDialog(
    title: Text(rommText(context, 'connect')),
    content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      FocusableTextField(controller: _address, enabled: !_busy && widget.source == null,
        keyboardType: TextInputType.url, decoration: InputDecoration(labelText: rommText(context, 'serverAddress'))),
      const SizedBox(height: 12),
      FocusableTextField(controller: _name, enabled: !_busy, decoration: InputDecoration(labelText: rommText(context, 'serverName'))),
      if (_manual) ...[const SizedBox(height: 12), FocusableTextField(controller: _token, enabled: !_busy,
        obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: InputDecoration(labelText: rommText(context, 'token'))),
        const SizedBox(height: 8), Text(rommText(context, 'manualTokenHelp'))],
      if (!_busy) TextButton(onPressed: () => setState(() => _manual = !_manual),
        child: Text(rommText(context, _manual ? 'pair' : 'manualToken'))),
      if (_address.text.startsWith('http://')) Text(rommText(context, 'httpHelp')),
      if (_verification != null && _busy) ...[
        const SizedBox(height: 16), Text(rommText(context, 'pairHelp')),
        Semantics(label: _code, child: SelectableText(_code, textDirection: TextDirection.ltr, style: Theme.of(context).textTheme.headlineMedium)),
        ColoredBox(color: Colors.white, child: QrImageView(data: _verification.toString(), size: 200)),
        TextButton(onPressed: () => launchUrl(_verification!, mode: LaunchMode.externalApplication),
          child: Text(rommText(context, 'openApproval'))),
      ],
      if (_busy) Semantics(liveRegion: true, label: rommText(context, 'pairing'), child: const LinearProgressIndicator()),
      if (_error.isNotEmpty) Semantics(liveRegion: true, child: Text(rommText(context, _error))),
    ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(rommText(context, 'cancel'))),
      FilledButton(onPressed: _busy ? null : _start, child: Text(rommText(context, _manual ? 'connect' : 'pair')))],
  );
}
