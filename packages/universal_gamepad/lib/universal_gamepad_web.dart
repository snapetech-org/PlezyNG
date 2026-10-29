/// Web entry point for the `universal_gamepad` plugin.
///
/// Referenced by `pubspec.yaml` (`web: fileName:`) so the generated
/// `web_plugin_registrant.dart` can resolve [WebGamepad]. Not part of the
/// public API; apps should import `package:universal_gamepad/universal_gamepad.dart`.
library;

export 'src/web_platform.dart' show WebGamepad;
