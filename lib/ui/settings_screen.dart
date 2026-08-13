import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/background.dart';
import '../services/notification_service.dart';
import '../services/settings_store.dart';
import '../state/app_state.dart';
import 'rules_editor_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appState,
    builder: (BuildContext context, Widget? child) => Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: <Widget>[
          const _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: Text(appState.email ?? '—'),
            subtitle: const Text('Connected over IMAP, read only'),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Last sync'),
            subtitle: Text(
              appState.lastSync == null
                  ? 'Never'
                  : DateFormat(
                      'EEE d MMM, HH:mm:ss',
                    ).format(appState.lastSync!),
            ),
          ),
          if (appState.lastError != null)
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Last sync failed'),
              subtitle: Text(appState.lastError!),
            ),

          const _SectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Notify about flagged mail'),
            subtitle: const Text(
              'Fires from the background poll, whether or not the app is open. '
              'Only decisive interview, offer and assessment mail notifies; '
              '"Needs review" never does.',
            ),
            value: appState.notificationsEnabled,
            onChanged: appState.setNotificationsEnabled,
          ),
          if (!appState.systemNotificationsGranted)
            ListTile(
              leading: Icon(
                Icons.warning_amber_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Android is blocking notifications'),
              subtitle: const Text(
                'Syncs still run, but nothing will be shown. Tap to open the '
                'system notification settings for this app.',
              ),
              onTap: () async {
                await NotificationService.openSystemSettings();
                await appState.refreshPermissionState();
              },
            ),
          ListTile(
            leading: const Icon(Icons.notification_add_outlined),
            title: const Text('Send a test notification'),
            onTap: () async {
              await NotificationService.showTest();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Test notification sent.')),
              );
            },
          ),

          const _SectionHeader('Background sync'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Check every'),
            subtitle: Text(
              '${_describeMinutes(appState.pollMinutes)} — Android enforces a '
              '15-minute minimum and batches runs, so treat this as '
              '"no more often than".',
            ),
            trailing: DropdownButton<int>(
              value: appState.pollMinutes,
              onChanged: (int? value) {
                if (value != null) appState.setPollMinutes(value);
              },
              items: SettingsStore.pollMinuteChoices
                  .map(
                    (int minutes) => DropdownMenuItem<int>(
                      value: minutes,
                      child: Text(_describeMinutes(minutes)),
                    ),
                  )
                  .toList(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Messages scanned per sync'),
            subtitle: const Text(
              'The newest N messages in the inbox. Higher survives more missed '
              'runs but uses more mobile data.',
            ),
            trailing: DropdownButton<int>(
              value: appState.fetchCount,
              onChanged: (int? value) {
                if (value != null) appState.setFetchCount(value);
              },
              items: SettingsStore.fetchCountChoices
                  .map(
                    (int count) => DropdownMenuItem<int>(
                      value: count,
                      child: Text('$count'),
                    ),
                  )
                  .toList(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.battery_alert_outlined),
            title: const Text('Exempt from battery optimisation'),
            subtitle: const Text(
              'Required in practice. Xiaomi, Samsung, Oppo and Vivo builds kill '
              'background work aggressively; without an exemption the poll can '
              'be delayed by hours or skipped. Find this app in the list and '
              'set it to "Not optimised" / "No restrictions".',
            ),
            onTap: _openBatterySettings,
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow_outlined),
            title: const Text('Run a background sync now'),
            subtitle: const Text(
              'Queues a real WorkManager job, so this tests the same path that '
              'runs when the app is closed.',
            ),
            onTap: () async {
              await BackgroundScheduler.runOnceNow();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Background job queued. Android decides when it runs.',
                  ),
                ),
              );
            },
          ),

          const _SectionHeader('Detection'),
          ListTile(
            leading: const Icon(Icons.rule),
            title: const Text('Detection rules'),
            subtitle: Text(
              'Notify at ${appState.rules.notifyThreshold} · review at '
              '${appState.rules.reviewThreshold} · '
              '${appState.rules.mutedSenders.length} muted senders',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const RulesEditorScreen(),
              ),
            ),
          ),

          const _SectionHeader('Danger zone'),
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('Disconnect and erase'),
            subtitle: const Text(
              'Deletes the stored App Password, the cached mail and all '
              'settings, and cancels the background poll.',
            ),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (BuildContext context) => AlertDialog(
                  title: const Text('Disconnect?'),
                  content: const Text(
                    'The App Password, cached mail and your edited rules will '
                    'be erased from this device. Your Gmail account is not '
                    'touched.',
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !context.mounted) return;
              await appState.signOut();
              if (!context.mounted) return;
              Navigator.of(context).popUntil((Route<void> r) => r.isFirst);
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    ),
  );

  /// Opens the system list of battery-optimised apps.
  ///
  /// Deliberately the settings list rather than
  /// `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: the direct request needs the
  /// `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission, which Play Store policy
  /// restricts to a narrow set of app types.
  static Future<void> _openBatterySettings() async {
    await const AndroidIntent(
      action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    ).launch();
  }

  static String _describeMinutes(int minutes) => minutes < 60
      ? '$minutes minutes'
      : '${minutes ~/ 60} hour${minutes ~/ 60 == 1 ? '' : 's'}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    ),
  );
}
