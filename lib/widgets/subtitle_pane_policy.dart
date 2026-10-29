import 'package:flutter/widgets.dart';

/// App-caption density policy for workspace surfaces. Native authored subtitle
/// tracks remain under their existing player controls.
class SubtitlePanePolicy extends InheritedWidget {
  const SubtitlePanePolicy({super.key, required this.visible, required super.child});
  final bool visible;
  static SubtitlePanePolicy? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SubtitlePanePolicy>();
  @override
  bool updateShouldNotify(SubtitlePanePolicy oldWidget) => visible != oldWidget.visible;
}
