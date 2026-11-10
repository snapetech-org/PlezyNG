import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/multiview/desktop_workspace_views.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.pleazyng/workspace_views');
  const geometry = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final calls = <MethodCall>[];
  late DesktopWorkspaceViews views;
  late Future<Object?> Function(MethodCall) native;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    calls.clear();
    native = (call) async => call.method == 'available' ? true : null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return native(call);
    });
    views = DesktopWorkspaceViews(channel: channel);
  });
  tearDown(() {
    views.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('rejects reusing a view already owned by the application', () async {
    native = (call) async {
      if (call.method == 'available') return true;
      if (call.method == 'create') return {'viewId': binding.platformDispatcher.views.first.viewId};
      return null;
    };
    expect(await views.open('reader', geometryKey: geometry, title: 'Reader'), isFalse);
    expect(views.detachedIds, isEmpty);
    expect(calls.map((call) => call.method), ['available', 'create', 'close']);
    expect(calls.last.arguments['token'], calls[1].arguments['token']);
  });

  test('availability failure retires its lease and permits retry', () async {
    native = (call) async {
      if (call.method == 'available') throw PlatformException(code: 'temporary');
      return null;
    };
    expect(await views.open('reader', geometryKey: geometry, title: 'Reader'), isFalse);
    expect(await views.open('reader', geometryKey: geometry, title: 'Reader'), isFalse);
    expect(calls.where((call) => call.method == 'available'), hasLength(2));
    expect(calls.where((call) => call.method == 'create'), isEmpty);
  });

  test('duplicate requests cannot create two windows and close cancels a pending create', () async {
    final requested = Completer<void>();
    final reply = Completer<Object?>();
    native = (call) async {
      if (call.method == 'available') return true;
      if (call.method == 'create') {
        requested.complete();
        return reply.future;
      }
      return null;
    };
    final pending = views.open('reader', geometryKey: geometry, title: 'Reader');
    await requested.future;
    expect(await views.open('reader', geometryKey: geometry, title: 'Reader'), isFalse);
    await views.close('reader');
    reply.complete({'viewId': 1234});
    expect(await pending, isFalse);
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    expect(calls.where((call) => call.method == 'show'), isEmpty);
    expect(views.detachedIds, isEmpty);
  });

  test('retiring a profile while availability is pending cannot create a window', () async {
    final requested = Completer<void>();
    final reply = Completer<Object?>();
    native = (call) async {
      if (call.method == 'available') {
        requested.complete();
        return reply.future;
      }
      return null;
    };
    final pending = views.open('reader', geometryKey: geometry, title: 'Reader');
    await requested.future;
    final old = views;
    views = DesktopWorkspaceViews(channel: channel);
    old.dispose();
    reply.complete(true);
    expect(await pending, isFalse);
    expect(calls.where((call) => call.method == 'create'), isEmpty);
  });

  test('native metadata contains a bounded title and opaque identity only', () async {
    native = (call) async {
      if (call.method == 'available') return true;
      return null;
    };
    await views.open('private-session', geometryKey: geometry, title: '${'A' * 300}\n\u0000');
    final arguments = calls.singleWhere((call) => call.method == 'create').arguments as Map;
    expect(arguments.keys.toSet(), {'token', 'geometryKey', 'title', 'width', 'height'});
    expect(arguments['title'], 'A' * 256);
    expect(arguments['token'], matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
    expect(arguments.values, isNot(contains('private-session')));
  });
}
