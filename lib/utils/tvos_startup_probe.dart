import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lets native debug qualification await the real app's asynchronous DB open.
/// Release builds do not register this channel or collect its result.
final tvosStartupProbe = TvosStartupProbe();

class TvosStartupProbe {
  TvosStartupProbe({this.channel = const MethodChannel('org.snapetech.pleazyng/startup_qualification')});

  final MethodChannel channel;
  final Completer<String> _databaseVersion = Completer<String>();
  bool _registered = false;

  bool register({required bool isTvos}) {
    if (!kDebugMode || !isTvos) return false;
    if (_registered) return true;
    _registered = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'waitForDatabase') throw MissingPluginException();
      return {'sqliteVersion': await _databaseVersion.future};
    });
    return true;
  }

  void databaseReady(String sqliteVersion) {
    if (_registered && !_databaseVersion.isCompleted) {
      _databaseVersion.complete(sqliteVersion);
    }
  }
}
