import 'package:flutter/services.dart';

class PlezyPreparation {
  static const channel = MethodChannel('org.plezy/preparation');
  static Future<void> schedule({bool subtitles = false}) => channel.invokeMethod<void>('schedule', {'subtitles': subtitles});
  static Future<void> cancel({bool subtitles = false}) => channel.invokeMethod<void>('cancel', {'subtitles': subtitles});
  static Future<bool> subtitlesMayRun() async => await channel.invokeMethod<bool>('subtitlesMayRun') == true;
}
