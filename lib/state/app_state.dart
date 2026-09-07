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
  all('All', 'Everything that needs a decision'),
  interviews('Interviews', 'Confirmed interview events'),
  offers('Offers', 'Offer letters and onboarding'),
  assessments('Assessments', 'Tests and take-home tasks'),
  needsReview('Needs review', 'Ambiguous wording, never notified'),
  recruiter('Recruiter', 'Outreach and acknowledgements');

  const InboxFilter(this.label, this.description);

  final String label;
  final String description;
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
  Map<MailCategory, int> _categoryCounts = const <MailCategory, int>{};
  InboxFilter _filter = InboxFilter.all;
  bool _showEverything = false;
  String _query = '';
  int _pollMinutes = SettingsStore.defaultPollMinutes;
  int _fetchCount = SettingsStore.defaultFetchCount;
  bool _notificationsEnabled = true;
  bool _systemNotificationsGranted = false;
  RuleSet _rules = RuleSet.defaults;
  DateTime? _lastSync;
  String? _lastError;
  String? _flash;
  MailItem? _pendingOpen;

  bool get booting => _booting;
  bool get syncing => _syncing;
  bool get isSignedIn => _email != null;
  String? get email => _email;
  List<MailItem> get items => _items;
  InboxFilter get filter => _filter;
  String get query => _query;

  int get flaggedCount => _counts[MailVerdict.notify] ?? 0;
  int get reviewCount => _counts[MailVerdict.review] ?? 0;
  int get recruiterCount => _counts[MailVerdict.informational] ?? 0;

  /// Count for one filter chip, or `null` when a number would say nothing
  /// useful (the "All" chip duplicates the list length below it).
  int? countFor(InboxFilter filter) => switch (filter) {
    InboxFilter.all => null,
    InboxFilter.interviews => _categoryCounts[MailCategory.interview] ?? 0,
    InboxFilter.offers => _categoryCounts[MailCategory.offer] ?? 0,
    InboxFilter.assessments => _categoryCounts[MailCategory.assessment] ?? 0,
    InboxFilter.needsReview => reviewCount,
    InboxFilter.recruiter => recruiterCount,
  };

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

  /// Message the user asked to open by tapping a notification. Consumed by the
  /// list, which owns the navigator.
  MailItem? consumePendingOpen() {
    final item = _pendingOpen;
    _pendingOpen = null;
    return item;
  }

  Future<void> boot() async {
    await NotificationService.init();
    NotificationService.onMailTapped = requestOpen;
    final credentials = await CredentialsStore.read();
    _email = credentials?.email;
    await _loadSettings();
    if (credentials != null) {
      await _loadItems();
      await BackgroundScheduler.schedule(_pollMinutes);
      final launchUid = await NotificationService.launchedFromMailUid();
      if (launchUid != null) await requestOpen(launchUid);
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
      InboxFilter.recruiter => const <MailVerdict>{MailVerdict.informational},
      InboxFilter.all => MailVerdict.listedByDefault,
      InboxFilter.offers ||
      InboxFilter.interviews ||
      InboxFilter.assessments => MailVerdict.notifiable,
    };
  }

  MailCategory? get _visibleCategory => switch (_filter) {
    InboxFilter.offers => MailCategory.offer,
    InboxFilter.interviews => MailCategory.interview,
    InboxFilter.assessments => MailCategory.assessment,
    InboxFilter.all ||
    InboxFilter.needsReview ||
    InboxFilter.recruiter => null,
  };

  Future<void> _loadItems() async {
    _items = await MailDatabase.list(
      verdicts: _visibleVerdicts,
      category: _visibleCategory,
      query: _query,
    );
    _counts = await MailDatabase.countsByVerdict();
    _categoryCounts = await MailDatabase.countsByCategory();
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
    _categoryCounts = const <MailCategory, int>{};
    _rules = RuleSet.defaults;
    _filter = InboxFilter.all;
    _showEverything = false;
    _query = '';
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
      _flash = _describe(result);
    } else {
      _flash = result.error;
    }
    await _loadItems();
    _lastSync = await SettingsStore.readLastSync();
    _lastError = await SettingsStore.readLastError();
    _syncing = false;
    notifyListeners();
  }

  static String _describe(SyncResult result) {
    if (result.added == 0) return 'No new mail.';
    final parts = <String>['${result.added} new'];
    if (result.flagged > 0) parts.add('${result.flagged} flagged');
    if (result.needsReview > 0) parts.add('${result.needsReview} to review');
    if (result.recruiter > 0) parts.add('${result.recruiter} recruiter');
    if (parts.length == 1) parts.add('nothing important');
    final summary = parts.join(' · ');
    return result.backlog > 0
        ? '$summary — ${result.backlog} more waiting for the next sync.'
        : summary;
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

  Future<void> setQuery(String query) async {
    if (query == _query) return;
    _query = query;
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

  /// Undo for a swipe. The row is still in the table, so this is a flag flip
  /// rather than a re-fetch.
  Future<void> unarchive(int uid) async {
    await MailDatabase.setArchived(uid: uid, archived: false);
    await _loadItems();
    notifyListeners();
  }

  /// Loads the message behind a tapped notification so the list can open it.
  Future<void> requestOpen(int uid) async {
    final item = await MailDatabase.byUid(uid);
    if (item == null) return;
    _pendingOpen = item;
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

  /// Re-reads the whole inbox window on the next sync. The escape hatch for
  /// "the app has missed something": it drops the UID cursor so the newest
  /// [fetchCount] messages are classified again by the current rules.
  Future<void> rescanInbox() async {
    await SettingsStore.clearSyncCursor();
    await SyncService.reclassifyCached();
    await sync();
  }
}
