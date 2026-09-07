import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/mail_item.dart';

/// Local notifications for flagged mail.
///
/// Everything here has to work from the WorkManager background isolate as well
/// as the UI isolate, so [init] is idempotent and called from both.
class NotificationService {
  const NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Interviews and offers. Separate from assessments so the two can be
  /// silenced independently in Android's own settings, and so an offer never
  /// arrives with the same weight as a coding test.
  static const AndroidNotificationChannel _urgentChannel =
      AndroidNotificationChannel(
        'interviews_offers_v1',
        'Interviews and offers',
        description:
            'Interview invitations and job offers detected in your inbox.',
        // max, not high: the entire point of the app is that these must not be
        // missed.
        importance: Importance.max,
      );

  /// Assessments and tests. Deadline-bearing but not an appointment, so they
  /// get their own, quieter channel.
  static const AndroidNotificationChannel _taskChannel =
      AndroidNotificationChannel(
        'assessments_v1',
        'Assessments and tests',
        description: 'Coding tests and take-home assignments to complete.',
        importance: Importance.high,
      );

  /// Groups the per-message notifications under one heading in the shade.
  static const String _groupKey = 'important_mail_group';

  /// Id of the summary notification that heads the group. Well above any UID
  /// remainder so it cannot collide with a message.
  static const int _summaryId = 2147483646;

  /// Called with a message UID when the user taps a notification. Set by the
  /// UI layer; unset in the background isolate, where there is nothing to
  /// navigate.
  static void Function(int uid)? onMailTapped;

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _handleResponse,
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(_urgentChannel);
    await android?.createNotificationChannel(_taskChannel);
    _initialized = true;
  }

  static void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    final uid = int.tryParse(payload);
    if (uid != null) onMailTapped?.call(uid);
  }

  /// UID of the message whose notification launched the app from cold, or
  /// `null` when it was started normally.
  static Future<int?> launchedFromMailUid() async {
    await init();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final payload = details?.notificationResponse?.payload;
    return payload == null ? null : int.tryParse(payload);
  }

  /// Android 13+ gates notifications behind a runtime permission. Returns
  /// `false` if the user declined, in which case background syncs still run but
  /// nothing is shown.
  static Future<bool> requestPermission() async {
    await init();
    final granted = await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    return granted ?? false;
  }

  static Future<bool> areEnabled() async {
    await init();
    final enabled = await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.areNotificationsEnabled();
    return enabled ?? false;
  }

  static AndroidNotificationChannel _channelFor(MailCategory category) =>
      category == MailCategory.assessment ? _taskChannel : _urgentChannel;

  static Future<void> showMail(MailItem item) async {
    await init();
    final channel = _channelFor(item.category);
    final body = item.snippet.isEmpty
        ? item.displayFrom
        : '${item.displayFrom} — ${item.snippet}';
    await _plugin.show(
      id: item.notificationId,
      title: '${item.category.label}: ${item.subject}',
      body: body,
      payload: item.uid.toString(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: Priority.high,
          groupKey: _groupKey,
          category: AndroidNotificationCategory.email,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: item.subject,
            summaryText: item.category.label,
          ),
        ),
      ),
    );
  }

  /// Heads the group with a one-line summary. Without it Android shows a bare
  /// "2 notifications" row, which says nothing about what arrived.
  static Future<void> showSummary(List<MailItem> items) async {
    if (items.length < 2) return;
    await init();
    final byCategory = <MailCategory, int>{};
    for (final item in items) {
      byCategory[item.category] = (byCategory[item.category] ?? 0) + 1;
    }
    final parts = byCategory.entries
        .map((MapEntry<MailCategory, int> e) => '${e.value} ${e.key.label}')
        .join(' · ');
    await _plugin.show(
      id: _summaryId,
      title: '${items.length} messages need you',
      body: parts,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _urgentChannel.id,
          _urgentChannel.name,
          channelDescription: _urgentChannel.description,
          importance: Importance.max,
          priority: Priority.high,
          groupKey: _groupKey,
          setAsGroupSummary: true,
          styleInformation: InboxStyleInformation(
            items
                .map((MailItem item) => item.subject)
                .toList(growable: false),
            contentTitle: '${items.length} messages need you',
            summaryText: parts,
          ),
        ),
      ),
    );
  }

  static Future<void> showTest() async {
    await init();
    await _plugin.show(
      id: 0,
      title: 'Test alert',
      body: 'If you can see this, background alerts will reach you.',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _urgentChannel.id,
          _urgentChannel.name,
          channelDescription: _urgentChannel.description,
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }

  /// Opens the system notification settings for this app, for when the user has
  /// denied the permission and can no longer be prompted.
  static Future<void> openSystemSettings() async {
    await init();
    await _plugin.openAppNotificationSettings();
  }
}
