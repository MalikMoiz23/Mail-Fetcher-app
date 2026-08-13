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

  static const String _channelId = 'important_mail_v1';
  static const String _channelName = 'Important mail';
  static const String _channelDescription =
      'Interviews, offers and assessments detected in your inbox.';

  /// Groups the per-message notifications under one heading in the shade.
  static const String _groupKey = 'important_mail_group';

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            // max, not high: the entire point of the app is that these must not
            // be missed.
            importance: Importance.max,
          ),
        );
    _initialized = true;
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

  static Future<void> showMail(MailItem item) async {
    await init();
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
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
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

  static Future<void> showTest() async {
    await init();
    await _plugin.show(
      id: 0,
      title: 'Interview: Test notification',
      body: 'If you can see this, background alerts will reach you.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          groupKey: _groupKey,
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
