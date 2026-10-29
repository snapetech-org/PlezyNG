import 'package:flutter/material.dart';
import '../../games/romm/romm_controller.dart';

/// Nested pages retire even when a profile changes below their Navigator route.
class RommSessionPage extends StatefulWidget {
  const RommSessionPage({super.key, required this.controller, required this.child});
  final RommController controller;
  final Widget child;
  @override State<RommSessionPage> createState() => _RommSessionPageState();
}
class _RommSessionPageState extends State<RommSessionPage> {
  @override void initState() { super.initState(); widget.controller.addListener(_changed); }
  void _changed() {
    if (widget.controller.current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context); if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
  }
  @override void dispose() { widget.controller.removeListener(_changed); super.dispose(); }
  @override Widget build(BuildContext context) => widget.controller.current ? widget.child : const SizedBox.shrink();
}
Future<T?> rommPush<T>(BuildContext context, RommController controller, Widget child) => Navigator.of(context).push<T>(
  MaterialPageRoute(builder: (_) => RommSessionPage(controller: controller, child: child)));
