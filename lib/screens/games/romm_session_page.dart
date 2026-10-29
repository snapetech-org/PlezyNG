import 'package:flutter/material.dart';
import '../../games/romm/romm_controller.dart';

/// Nested pages retire even when a profile changes below their Navigator route.
class RommSessionPage extends StatefulWidget {
  const RommSessionPage({super.key, required this.controller, required this.child, this.connectionId});
  final RommController controller;
  final Widget child;
  final String? connectionId;
  @override State<RommSessionPage> createState() => _RommSessionPageState();
}
class _RommSessionPageState extends State<RommSessionPage> {
  bool get _current => widget.controller.current && (widget.connectionId == null || widget.controller.hasConnection(widget.connectionId!));
  @override void initState() { super.initState(); widget.controller.addListener(_changed); if (!_current) _changed(); }
  void _changed() {
    if (_current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context); if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }
  @override void dispose() { widget.controller.removeListener(_changed); super.dispose(); }
  @override Widget build(BuildContext context) => _current ? widget.child : const SizedBox.shrink();
}
Future<T?> rommPush<T>(BuildContext context, RommController controller, Widget child, {String? connectionId}) => Navigator.of(context).push<T>(
  MaterialPageRoute(builder: (_) => RommSessionPage(controller: controller, connectionId: connectionId, child: child)));

/// Dialog routes live above their parent page, so they need the same profile
/// ownership as players and details. Removing the page alone leaves a dialog.
Future<T?> rommDialog<T>({required BuildContext context, required RommController controller,
    required WidgetBuilder builder, String? connectionId}) => showDialog<T>(context: context,
  builder: (dialog) => RommSessionPage(controller: controller, connectionId: connectionId,
    child: Builder(builder: builder)));
