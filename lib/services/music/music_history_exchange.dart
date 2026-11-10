import 'dart:async';
import 'dart:math';

import 'music_history_reconciliation.dart';
import 'music_library_store.dart';

class MusicHistoryExchange {
  MusicHistoryExchange({
    required this.allowed,
    required this.accounts,
    required this.exportPage,
    required this.merge,
    required this.send,
    this.pageTimeout = const Duration(seconds: 20),
  });

  final bool Function() allowed;
  final Set<String> Function() accounts;
  final Future<MusicHistoryPage> Function(Set<String>, (int, String)?, bool Function()) exportPage;
  final Future<bool> Function(List<MusicHistoryEntry>, bool Function()) merge;
  final void Function(Map<String, dynamic>) send;
  final Duration pageTimeout;
  int _generation = 0, _sequence = 0;
  int _requestEpoch = 0;
  bool _closed = false, _serving = false, _merging = false;
  String? _request;
  Set<String> _accounts = {};
  (int, String)? _before;
  Completer<bool>? _pending;
  Timer? _timer;
  Timer? _deadline;
  static final _requestPattern = RegExp(r'^[a-f0-9]{32}$');

  Future<bool> request() {
    final selected = accounts();
    if (_closed || !allowed() || _pending != null || selected.isEmpty || selected.length > 32) {
      return Future.value(false);
    }
    final random = Random.secure();
    _request = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _accounts = selected;
    _before = null;
    _sequence = 0;
    final pending = _pending = Completer<bool>();
    final epoch = ++_requestEpoch;
    _deadline = Timer(const Duration(minutes: 5), () {
      if (epoch == _requestEpoch) _finish(false);
    });
    _nextPage();
    return pending.future;
  }

  void _nextPage() {
    if (_closed || !allowed() || _request == null || _sequence >= 10000) {
      _finish(false);
      return;
    }
    _timer?.cancel();
    final epoch = _requestEpoch;
    _timer = Timer(pageTimeout, () {
      if (epoch == _requestEpoch) _finish(false);
    });
    _send({
      'version': 1,
      'op': 'request',
      'request': _request,
      'sequence': _sequence,
      'accounts': _accounts.toList(),
      'before': _cursor(_before),
    });
  }

  List<Object>? _cursor((int, String)? cursor) => cursor == null ? null : [cursor.$1, cursor.$2];

  void receive(Map<String, dynamic>? data) {
    if (_closed || !allowed() || data == null || data['version'] != 1) return;
    try {
      if (!boundedMusicHistoryMessage(data)) throw const FormatException('Oversized history page');
      final id = data['request'], sequence = data['sequence'];
      if (id is! String || !_requestPattern.hasMatch(id) || sequence is! int || sequence < 0 || sequence >= 10000) {
        return;
      }
      switch (data['op']) {
        case 'request':
          if (!_serving) unawaited(_serve(id, sequence, data));
        case 'page':
          if (id == _request && sequence == _sequence && !_merging) unawaited(_page(data));
        case 'error':
          if (id == _request && sequence == _sequence) _finish(false);
      }
    } catch (_) {
      if (data['request'] == _request) _finish(false);
    }
  }

  Future<void> _serve(String id, int sequence, Map<String, dynamic> data) async {
    _serving = true;
    final generation = _generation;
    var expired = false;
    bool current() => !_closed && !expired && generation == _generation && allowed();
    try {
      if (data.keys.any((key) => !{'version', 'op', 'request', 'sequence', 'accounts', 'before'}.contains(key))) {
        throw const FormatException('Invalid history request');
      }
      final raw = data['accounts'];
      if (raw is! List ||
          raw.isEmpty ||
          raw.length > 32 ||
          raw.any((account) => account is! String || !musicHistoryAccountPattern.hasMatch(account))) {
        throw const FormatException('Invalid history accounts');
      }
      final selected = raw.cast<String>().toSet();
      final before = historyCursorFromWire(data['before']);
      final page = await exportPage(selected, before, current).timeout(
        pageTimeout,
        onTimeout: () {
          expired = true;
          throw TimeoutException('History page expired');
        },
      );
      if (!current()) return;
      final reply = {
        'version': 1,
        'op': 'page',
        'request': id,
        'sequence': sequence,
        'entries': page.entries.map(musicHistoryToWire).toList(),
        'cursor': _cursor(page.cursor),
      };
      if (!boundedMusicHistoryMessage(reply)) throw const FormatException('Oversized history page');
      _send(reply);
    } catch (_) {
      if (!_closed && generation == _generation && allowed()) {
        _send({'version': 1, 'op': 'error', 'request': id, 'sequence': sequence});
      }
    } finally {
      if (generation == _generation) _serving = false;
    }
  }

  Future<void> _page(Map<String, dynamic> data) async {
    _merging = true;
    final generation = _generation;
    final sequence = _sequence;
    final epoch = _requestEpoch;
    bool current() =>
        !_closed &&
        generation == _generation &&
        epoch == _requestEpoch &&
        sequence == _sequence &&
        _pending != null &&
        allowed();
    try {
      if (data.keys.any((key) => !{'version', 'op', 'request', 'sequence', 'entries', 'cursor'}.contains(key))) {
        throw const FormatException('Invalid history reply');
      }
      final raw = data['entries'];
      if (raw is! List || raw.length > 8) throw const FormatException('Invalid history page');
      final entries = raw.map(musicHistoryFromWire).toList();
      final cursor = historyCursorFromWire(data['cursor']);
      var prior = _before;
      for (final entry in entries) {
        if (!_accounts.contains(entry.account) || (prior != null && compareHistoryCursor(entry.cursor, prior) >= 0)) {
          throw const FormatException('Out-of-order or unauthorized history page');
        }
        prior = entry.cursor;
      }
      if (cursor != null &&
          ((_before != null && compareHistoryCursor(cursor, _before!) >= 0) ||
              (prior != null && compareHistoryCursor(cursor, prior) > 0))) {
        throw const FormatException('History cursor did not advance');
      }
      if (!await merge(entries, current) || !current()) {
        if (generation == _generation && epoch == _requestEpoch) _finish(false);
        return;
      }
      if (cursor == null) {
        _finish(true);
      } else {
        _before = cursor;
        _sequence++;
        _merging = false;
        _nextPage();
      }
    } catch (_) {
      if (generation == _generation && epoch == _requestEpoch) _finish(false);
    } finally {
      if (generation == _generation && epoch == _requestEpoch) _merging = false;
    }
  }

  void _send(Map<String, dynamic> data) {
    try {
      send(data);
    } catch (_) {
      _finish(false);
    }
  }

  void _finish(bool result) {
    _requestEpoch++;
    _timer?.cancel();
    _deadline?.cancel();
    final pending = _pending;
    _pending = null;
    _request = null;
    _merging = false;
    if (pending?.isCompleted == false) pending!.complete(result);
  }

  void reset() {
    _generation++;
    _serving = false;
    _finish(false);
  }

  void close() {
    _closed = true;
    reset();
  }
}
