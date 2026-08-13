import 'package:flutter/foundation.dart';

import '../models/mail_item.dart';
import '../models/rule_set.dart';
import '../services/background.dart';
import '../services/credentials_store.dart';
import '../services/imap_service.dart';
import '../services/mail_database.dart';
import '../services/notification_service.dart';
import '../services/settings_store.dart';
import '../services/sync_service.dart';

/// The list's top-level filter chips.
enum InboxFilter {
  all('All'),
  offers('Offers'),
  interviews('Interviews'),
  assessments('Assessments'),
  needsReview('Needs review');

  const InboxFilter(this.label);

  final String label;
}

/// Single mutable source of truth for the UI.
///
/// One global instance is enough here: the app has one account, one list and one
/// settings page, so a dependency-injection layer would be pure ceremony.
final AppState appState = AppState();

class AppState extends ChangeNotifier {
  bool _booting = true;
  bool _syncing = false;
  String? _email;
  List<MailItem> _items = const <MailItem>[];
  Map<MailVerdict, int> _counts = const <MailVerdict, int>{};
  InboxFilter _filter = InboxFilter.all;
  bool _showEverything = false;
  int _pollMinutes = SettingsStore.defaultPollMinutes;
  int _fetchCount = SettingsStore.defaultFetchCount;
  bool _notificationsEnabled = true;
  bool _systemNotificationsGranted = false;
  RuleSet _rules = RuleSet.defaults;
  DateTime? _lastSync;
  String? _lastError;
  String? _flash;

  bool get booting => _booting;
  bool get syncing => _syncing;
  bool get isSignedIn => _email != null;
  String? get email => _email;
  List<MailItem> get items => _items;
  InboxFilter get filter => _filter;

  int get flaggedCount => _counts[MailVerdict.notify] ?? 0;
  int get reviewCount => _counts[MailVerdict.review] ?? 0;

  /// When true the list also shows ignored mail and rejections, so the user can
  /// check what the rules filtered out instead of trusting them blindly.
  bool get showEverything => _showEverything;

  int get pollMinutes => _pollMinutes;
  int get fetchCount => _fetchCount;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get systemNotificationsGranted => _systemNotificationsGranted;
  RuleSet get rules => _rules;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;

  /// One-shot message for the UI to show in a snackbar.
  String? consumeFlash() {
    final message = _flash;
    _flash = null;
    return message;
  }

  Future<void> boot() async {
    await NotificationService.init();
    final credentials = await CredentialsStore.read();
    _email = credentials?.email;
    await _loadSettings();
    if (credentials != null) {
      await _loadItems();
      await BackgroundScheduler.schedule(_pollMinutes);
    }
    _booting = false;
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    _rules = await SettingsStore.readRules();
    _pollMinutes = await SettingsStore.readPollMinutes();
    _fetchCount = await SettingsStore.readFetchCount();
    _notificationsEnabled = await SettingsStore.readNotificationsEnabled();
    _systemNotificationsGranted = await NotificationService.areEnabled();
    _lastSync = await SettingsStore.readLastSync();
    _lastError = await SettingsStore.readLastError();
  }

  /// Verdicts the current filter should show. "Show everything" widens this to
  /// every verdict so nothing is hidden from an audit.
  Set<MailVerdict> get _visibleVerdicts {
    if (_showEverything) return MailVerdict.values.toSet();
    return switch (_filter) {
      InboxFilter.needsReview => const <MailVerdict>{MailVerdict.review},
      InboxFilter.all => MailVerdict.listedByDefault,
      InboxFilter.offers ||
      InboxFilter.interviews ||
      InboxFilter.assessments => const <MailVerdict>{MailVerdict.notify},
    };
  }

  MailCategory? get _visibleCategory => switch (_filter) {
    InboxFilter.offers => MailCategory.offer,
    InboxFilter.interviews => MailCategory.interview,
    InboxFilter.assessments => MailCategory.assessment,
    InboxFilter.all || InboxFilter.needsReview => null,
  };

  Future<void> _loadItems() async {
    _items = await MailDatabase.list(
      verdicts: _visibleVerdicts,
      category: _visibleCategory,
    );
    _counts = await MailDatabase.countsByVerdict();
  }

  /// Verifies the credentials against Gmail before storing them, so a typo in
  /// the App Password fails here instead of silently forever in the background.
  Future<String?> signIn({
    required String email,
    required String appPassword,
  }) async {
    final credentials = MailCredentials(
      email: email.trim(),
      // Google prints App Passwords in four space-separated blocks; IMAP wants
      // them without the spaces.
      appPassword: appPassword.replaceAll(RegExp(r'\s+'), ''),
    );
    try {
      await ImapService.verify(credentials);
    } on MailAuthException catch (error) {
      return error.message;
    }
    await CredentialsStore.save(credentials);
    _email = credentials.email;
    _systemNotificationsGranted = await NotificationService.requestPermission();
    await BackgroundScheduler.schedule(_pollMinutes);
    notifyListeners();
    await sync();
    return null;
  }

  Future<void> signOut() async {
    await BackgroundScheduler.cancel();
    await CredentialsStore.clear();
    await MailDatabase.wipe();
    await SettingsStore.clearAll();
    _email = null;
    _items = const <MailItem>[];
    _counts = const <MailVerdict, int>{};
    _rules = RuleSet.defaults;
    _filter = InboxFilter.all;
    _showEverything = false;
    _pollMinutes = SettingsStore.defaultPollMinutes;
    _fetchCount = SettingsStore.defaultFetchCount;
    _notificationsEnabled = true;
    _lastSync = null;
    _lastError = null;
    notifyListeners();
  }

  /// Foreground sync. Notifications are suppressed: the user is looking at the
  /// list right now, so buzzing the phone about what is on screen is noise.
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    final result = await SyncService.run(allowNotifications: false);
    if (result.isSuccess) {
      // Mail seen in the foreground counts as delivered, otherwise the next
      // background run would notify about mail already read.
      final pending = await MailDatabase.pendingNotifications();
      await MailDatabase.markNotified(pending.map((MailItem item) => item.uid));
      _flash = switch (result) {
        SyncResult(added: 0) => 'No new mail.',
        SyncResult(flagged: 0, needsReview: 0) =>
          '${result.added} new, nothing important.',
        SyncResult(needsReview: 0) =>
          '${result.added} new · ${result.flagged} flagged.',
        _ =>
          '${result.added} new · ${result.flagged} flagged · '
              '${result.needsReview} to review.',
      };
    } else {
      _flash = result.error;
    }
    await _loadItems();
    _lastSync = await SettingsStore.readLastSync();
    _lastError = await SettingsStore.readLastError();
    _syncing = false;
    notifyListeners();
  }

  Future<void> setFilter(InboxFilter filter) async {
    _filter = filter;
    await _loadItems();
    notifyListeners();
  }

  Future<void> setShowEverything(bool value) async {
    _showEverything = value;
    await _loadItems();
    notifyListeners();
  }

  /// Manual correction, which also pins the row against future rule changes.
  Future<void> setVerdict({
    required int uid,
    required MailVerdict verdict,
  }) async {
    await MailDatabase.setVerdict(uid: uid, verdict: verdict);
    await _loadItems();
    notifyListeners();
  }

  Future<void> archive(int uid) async {
    await MailDatabase.setArchived(uid: uid, archived: true);
    await _loadItems();
    notifyListeners();
  }

  Future<void> setPollMinutes(int minutes) async {
    _pollMinutes = minutes;
    await SettingsStore.writePollMinutes(minutes);
    await BackgroundScheduler.schedule(minutes);
    notifyListeners();
  }

  Future<void> setFetchCount(int count) async {
    _fetchCount = count;
    await SettingsStore.writeFetchCount(count);
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    await SettingsStore.writeNotificationsEnabled(enabled);
    if (enabled) {
      _systemNotificationsGranted =
          await NotificationService.requestPermission();
    }
    notifyListeners();
  }

  Future<void> refreshPermissionState() async {
    _systemNotificationsGranted = await NotificationService.areEnabled();
    notifyListeners();
  }

  /// Persists edited rules and immediately rescores cached mail, so the effect
  /// of a rule change is visible without waiting for the next poll.
  Future<int> updateRules(RuleSet rules) async {
    _rules = rules;
    await SettingsStore.writeRules(rules);
    final changed = await SyncService.reclassifyCached();
    await _loadItems();
    notifyListeners();
    return changed;
  }

  Future<int> resetRules() => updateRules(RuleSet.defaults);
}
