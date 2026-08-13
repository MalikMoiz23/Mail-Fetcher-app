import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import 'settings_store.dart';
import 'sync_service.dart';

/// Unique name of the periodic work. Reusing it means re-registering updates the
/// existing schedule instead of stacking duplicates.
const String kSyncUniqueName = 'importantMailPeriodicSync';

/// Value handed to the task handler. Kept separate from the unique name so the
/// handler can branch if more task types are added later.
const String kSyncTaskName = 'importantMailSync';

/// WorkManager entry point. Runs in its own isolate with no widget tree, so it
/// may only touch plugins and plain Dart.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((String taskName, Map<String, dynamic>? inputData) async {
    // The background isolate starts with no plugin registrations of its own.
    DartPluginRegistrant.ensureInitialized();
    if (taskName != kSyncTaskName) return true;
    try {
      final result = await SyncService.run(allowNotifications: true);
      // Returning false makes WorkManager retry with backoff. A missing
      // configuration is not retryable, so it reports success.
      return result.notConfigured || result.isSuccess;
    } on Object catch (error) {
      await SettingsStore.writeLastError(error.toString());
      return false;
    }
  });
}

/// Registers and cancels the periodic background sync.
class BackgroundScheduler {
  const BackgroundScheduler._();

  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher);
  }

  /// (Re)schedules the poll. Android clamps [minutes] to a 15-minute floor and
  /// batches runs with other apps' work, so the real interval is "at least
  /// this", never "exactly this".
  static Future<void> schedule(int minutes) async {
    final frequency = Duration(
      minutes: minutes < SettingsStore.minPollMinutes
          ? SettingsStore.minPollMinutes
          : minutes,
    );
    await Workmanager().registerPeriodicTask(
      kSyncUniqueName,
      kSyncTaskName,
      frequency: frequency,
      // update, not replace: changing the interval must not cancel a worker
      // that is mid-fetch.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: NetworkType.connected,
        // Deliberately not requiring battery-not-low or device-idle: an
        // interview invite matters more than a few mAh.
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(kSyncUniqueName);
  }

  /// Fires one immediate background run, used by the "Run a background sync
  /// now" button in Settings to prove the pipeline works end to end.
  static Future<void> runOnceNow() async {
    await Workmanager().registerOneOffTask(
      '${kSyncUniqueName}_oneOff',
      kSyncTaskName,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  static Future<bool> isScheduled() async {
    try {
      return await Workmanager().isScheduledByUniqueName(kSyncUniqueName);
    } on Object {
      return false;
    }
  }
}
