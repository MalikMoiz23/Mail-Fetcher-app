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
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: <Widget>[
          _Section(
            title: 'Account',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: Text(appState.email ?? '—'),
                subtitle: const Text('Connected over IMAP, read only'),
              ),
              const Divider(),
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
                trailing: appState.syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: 'Sync now',
                        icon: const Icon(Icons.refresh),
                        onPressed: appState.sync,
                      ),
              ),
              if (appState.lastError != null) ...<Widget>[
                const Divider(),
                ListTile(
                  leading: Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Last sync failed'),
                  subtitle: Text(appState.lastError!),
                ),
              ],
            ],
          ),
          _Section(
            title: 'Notifications',
            children: <Widget>[
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Notify about flagged mail'),
                subtitle: const Text(
                  'Interviews and offers arrive on a high-priority channel, '
                  'assessments on a quieter one. Recruiter mail and "Needs '
                  'review" never notify.',
                ),
                value: appState.notificationsEnabled,
                onChanged: appState.setNotificationsEnabled,
              ),
              if (!appState.systemNotificationsGranted) ...<Widget>[
                const Divider(),
                ListTile(
                  leading: Icon(
                    Icons.warning_amber_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: const Text('Android is blocking notifications'),
                  subtitle: const Text(
                    'Syncs still run, but nothing will be shown. Tap to open '
                    'the system notification settings for this app.',
                  ),
                  onTap: () async {
                    await NotificationService.openSystemSettings();
                    await appState.refreshPermissionState();
                  },
                ),
              ],
              const Divider(),
              ListTile(
                leading: const Icon(Icons.notification_add_outlined),
                title: const Text('Send a test notification'),
                subtitle: const Text(
                  'Confirms the channel is allowed to reach you.',
                ),
                onTap: () async {
                  await NotificationService.showTest();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Test notification sent.')),
                  );
                },
              ),
            ],
          ),
          _Section(
            title: 'Background sync',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Check every'),
                subtitle: Text(
                  '${_describeMinutes(appState.pollMinutes)} — Android '
                  'enforces a 15-minute minimum and batches runs, so treat '
                  'this as "no more often than".',
                ),
                trailing: DropdownButton<int>(
                  value: appState.pollMinutes,
                  underline: const SizedBox.shrink(),
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
              const Divider(),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Messages read on a first sync'),
                subtitle: const Text(
                  'Only the first sync reads a block of mail. After that the '
                  'app tracks where it got to and reads just what has arrived '
                  'since, so a higher number here costs nothing per run.',
                ),
                trailing: DropdownButton<int>(
                  value: appState.fetchCount,
                  underline: const SizedBox.shrink(),
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
              const Divider(),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('Re-scan the inbox'),
                subtitle: const Text(
                  'Forgets where the last sync got to and rescores everything '
                  'in the cache. Use it after editing the rules, or when '
                  'something is missing from the list.',
                ),
                onTap: () async {
                  await appState.rescanInbox();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Inbox re-scanned.')),
                  );
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.battery_alert_outlined),
                title: const Text('Exempt from battery optimisation'),
                subtitle: const Text(
                  'Required in practice. Xiaomi, Samsung, Oppo and Vivo builds '
                  'kill background work aggressively; without an exemption the '
                  'poll can be delayed by hours or skipped. Find this app in '
                  'the list and set it to "Not optimised".',
                ),
                onTap: _openBatterySettings,
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: const Text('Run a background sync now'),
                subtitle: const Text(
                  'Queues a real WorkManager job, so this tests the same path '
                  'that runs when the app is closed.',
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
            ],
          ),
          _Section(
            title: 'Detection',
            children: <Widget>[
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
                    builder: (BuildContext context) =>
                        const RulesEditorScreen(),
                  ),
                ),
              ),
            ],
          ),
          _Section(
            title: 'Danger zone',
            children: <Widget>[
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
                onTap: () => _confirmSignOut(context),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  static Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
          'The App Password, cached mail and your edited rules will be erased '
          'from this device. Your Gmail account is not touched.',
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
  }

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

/// A titled card. Grouping the rows into cards is what keeps a settings page
/// this long scannable.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
  );
}
