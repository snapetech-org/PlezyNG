import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  tearDown(LogRedactionManager.clearTrackedValues);

  test('redacts nested headers, arrays, keys and registered values', () {
    LogRedactionManager.registerToken('secret-canary-123');
    final tree = {
      'extra': [
        {
          'headers': {'Authorization': 'Bearer unknown-canary', 'Cookie': 'session=unregistered'},
        },
        {'secret-canary-123': 'value', 'detail': 'https://user:pass@example.test/?access_token=unknown-token'},
      ],
      'token_count': 7,
    };
    final safe = LogRedactionManager.redactStructured(tree);
    final encoded = jsonEncode(safe);
    for (final secret in ['secret-canary-123', 'unknown-canary', 'unregistered', 'user:pass', 'unknown-token']) {
      expect(encoded, isNot(contains(secret)));
    }
    expect((safe as Map)['token_count'], 7);
    expect((tree['extra'] as List).first, contains('headers'));
  });

  test('cycles and excessive depth terminate without rendering arbitrary objects', () {
    final cycle = <String, dynamic>{};
    cycle['cycle'] = cycle;
    expect(jsonEncode(LogRedactionManager.redactStructured(cycle)), contains('[CYCLE]'));
    expect(LogRedactionManager.redactStructured(Object()), '[REDACTED_OBJECT]');
  });

  test('scrubbed Sentry JSON retains event structure', () {
    final event = SentryEvent.fromJson({
      ...SentryEvent().toJson(),
      'extra': {
        'nested': {'password': 'canary'},
      },
    });
    final safe = SentryEvent.fromJson(LogRedactionManager.redactStructured(event.toJson()) as Map<String, dynamic>);
    expect(jsonEncode(safe.toJson()), isNot(contains('canary')));
    expect(safe.eventId, event.eventId);
  });
}
