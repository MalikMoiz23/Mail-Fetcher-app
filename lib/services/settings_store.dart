import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/rule_set.dart';

/// Non-secret settings, shared between the UI isolate and the WorkManager
/// background isolate.
///
/// Every getter reloads first: the two isolates hold separate in-memory caches,
/// so without [SharedPreferences.reload] the background sync would keep using
/// the rules that were current when its isolate started.
class SettingsStore {
  const SettingsStore._();

  static const String _rulesKey = 'rules_json';
  static const String _pollMinutesKey = 'poll_minutes';
  static const String _fetchCountKey = 'fetch_count';
  static const String _notifyKey = 'notifications_enabled';
  static const String _lastSyncKey = 'last_sync_ms';
  static const String _lastErrorKey = 'last_error';

  /// Android's WorkManager floor for periodic work. Anything smaller is
  /// silently raised to 15 by the platform.
  static const int minPollMinutes = 15;
  static const int defaultPollMinutes = 15;
  static const int defaultFetchCount = 40;

  /// How many of the newest INBOX messages each sync looks at. Small enough to
  /// stay cheap on mobile data, large enough to survive a few missed runs.
  static const List<int> fetchCountChoices = <int>[20, 40, 60, 100];
  static const List<int> pollMinuteChoices = <int>[15, 30, 60, 180, 360];

  static Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  static Future<RuleSet> readRules() async {
    final raw = (await _prefs()).getString(_rulesKey);
    if (raw == null || raw.isEmpty) return RuleSet.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return RuleSet.defaults;
      return RuleSet.fromJson(decoded);
    } on FormatException {
      return RuleSet.defaults;
    }
  }

  static Future<void> writeRules(RuleSet rules) async {
    await (await _prefs()).setString(_rulesKey, jsonEncode(rules.toJson()));
  }

  static Future<int> readPollMinutes() async {
    final value = (await _prefs()).getInt(_pollMinutesKey);
    if (value == null || value < minPollMinutes) return defaultPollMinutes;
    return value;
  }

  static Future<void> writePollMinutes(int minutes) async {
    await (await _prefs()).setInt(
      _pollMinutesKey,
      minutes < minPollMinutes ? minPollMinutes : minutes,
    );
  }

  static Future<int> readFetchCount() async =>
      (await _prefs()).getInt(_fetchCountKey) ?? defaultFetchCount;

  static Future<void> writeFetchCount(int count) async {
    await (await _prefs()).setInt(_fetchCountKey, count);
  }

  static Future<bool> readNotificationsEnabled() async =>
      (await _prefs()).getBool(_notifyKey) ?? true;

  static Future<void> writeNotificationsEnabled(bool enabled) async {
    await (await _prefs()).setBool(_notifyKey, enabled);
  }

  static Future<DateTime?> readLastSync() async {
    final ms = (await _prefs()).getInt(_lastSyncKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> writeLastSync(DateTime when) async {
    await (await _prefs()).setInt(_lastSyncKey, when.millisecondsSinceEpoch);
  }

  /// Last sync failure, surfaced in Settings. Cleared on the next success so a
  /// stale App Password shows up instead of failing silently forever.
  static Future<String?> readLastError() async =>
      (await _prefs()).getString(_lastErrorKey);

  static Future<void> writeLastError(String? error) async {
    final prefs = await _prefs();
    if (error == null || error.isEmpty) {
      await prefs.remove(_lastErrorKey);
    } else {
      await prefs.setString(_lastErrorKey, error);
    }
  }

  static Future<void> clearAll() async {
    final prefs = await _prefs();
    for (final key in <String>[
      _rulesKey,
      _pollMinutesKey,
      _fetchCountKey,
      _notifyKey,
      _lastSyncKey,
      _lastErrorKey,
    ]) {
      await prefs.remove(key);
    }
  }
}
