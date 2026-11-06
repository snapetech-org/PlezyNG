import 'package:flutter/material.dart';
import '../utils/layout_constants.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';

import 'focused_scroll_scaffold.dart';

/// Standard scaffold for settings pages made of ordinary list rows.
class SettingsPage extends StatelessWidget {
  final Widget title;
  final List<Widget>? children;
  final List<Widget>? slivers;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;
  final bool pinned;
  final bool automaticallyImplyLeading;
  final VoidCallback? onBackPressed;

  const SettingsPage({
    super.key,
    required this.title,
    required List<Widget> this.children,
    this.actions,
    this.padding,
    this.pinned = true,
    this.automaticallyImplyLeading = true,
    this.onBackPressed,
  }) : slivers = null;

  const SettingsPage.slivers({
    super.key,
    required this.title,
    required List<Widget> this.slivers,
    this.actions,
    this.pinned = true,
    this.automaticallyImplyLeading = true,
    this.onBackPressed,
  }) : children = null,
       padding = null;

  @override
  Widget build(BuildContext context) {
    final pageSlivers = slivers ?? [_buildListSliver()];
    return AppIconStyle(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxContentWidth = PlatformDetector.isTV() ? 1100 * TvLayoutConstants.scaleOf(context) : 960.0;
          final horizontalInset = ((constraints.maxWidth - maxContentWidth) / 2).clamp(0.0, double.infinity);
          return FocusedScrollScaffold(
            title: title,
            actions: actions,
            pinned: pinned,
            automaticallyImplyLeading: automaticallyImplyLeading,
            onBackPressed: onBackPressed,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                sliver: SliverMainAxisGroup(slivers: pageSlivers),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildListSliver() {
    final list = SliverList(delegate: SliverChildListDelegate(children!));
    final pagePadding = padding;
    if (pagePadding == null) return list;
    return SliverPadding(padding: pagePadding, sliver: list);
  }
}
