import '../models/mail_item.dart';
import 'classifier.dart';
import 'credentials_store.dart';
import 'imap_service.dart';
import 'mail_database.dart';
import 'notification_service.dart';
import 'settings_store.dart';

/// Outcome of one sync pass.
class SyncResult {
  const SyncResult({
    this.fetched = 0,
    this.added = 0,
    this.flagged = 0,
    this.needsReview = 0,
    this.recruiter = 0,
    this.notified = 0,
    this.backlog = 0,
    this.baseline = false,
    this.error,
    this.notConfigured = false,
  });

  final int fetched;
  final int added;

  /// New mail that earned a notification.
  final int flagged;

  /// New mail listed for review but not notified.
  final int needsReview;

  /// New mail filed under "Recruiter".
  final int recruiter;

  final int notified;

  /// New messages the server had that this run did not get to, because of the
  /// per-run cap. They are picked up by the next run rather than lost.
  final int backlog;

  /// True when this pass had to read the newest messages instead of only what
  /// arrived since the last run.
  final bool baseline;

  final String? error;

  /// No credentials stored yet, so there was nothing to do. Distinct from an
  /// error: the background worker must not retry-loop on this.
  final bool notConfigured;

  bool get isSuccess => error == null;
}

/// One sync pass: fetch, classify, store, notify.
///
/// Runs identically in the UI isolate (pull to refresh) and the WorkManager
/// background isolate, which is why it touches no Flutter widgets and takes all
/// of its configuration from [SettingsStore] and [CredentialsStore].
class SyncService {
  const SyncService._();

  /// Most notifications a single sync will post. See the comment at the call
  /// site for why a cap exists.
  static const int maxNotificationsPerRun = 10;

  /// Most messages one incremental run will classify. A backlog larger than
  /// this is worked through oldest-first over consecutive runs, so a phone
  /// that was offline for a week never has to do it all in one 10-minute
  /// WorkManager slot.
  static const int maxNewPerRun = 60;

  static Future<SyncResult> run({required bool allowNotifications}) async {
    try {
      final credentials = await CredentialsStore.read();
      if (credentials == null) {
        return const SyncResult(notConfigured: true);
      }

      final rules = await SettingsStore.readRules();
      final baselineCount = await SettingsStore.readFetchCount();
      final classifier = Classifier(rules);

      // A stored cursor is only trustworthy while the cache it describes still
      // exists. After a schema rebuild or a wipe the table is empty, and
      // trusting the cursor would leave the list blank until new mail happened
      // to arrive.
      final stored = await SettingsStore.readSyncCursor();
      final cursor = (await MailDatabase.rowCount()) == 0
          ? SyncCursor.none
          : stored;

      final batch = await ImapService.fetchNew(
        credentials: credentials,
        sinceUid: cursor.lastUid,
        uidValidity: cursor.uidValidity,
        baselineCount: baselineCount,
        maxMessages: baselineCount > maxNewPerRun
            ? baselineCount
            : maxNewPerRun,
      );

      final fresh = <MailItem>[];
      for (final message in batch.messages) {
        final verdict = classifier.classify(
          subject: message.subject,
          body: message.body,
          fromEmail: message.fromEmail,
        );
        fresh.add(
          MailItem(
            uid: message.uid,
            messageId: message.messageId,
            subject: message.subject,
            fromName: message.fromName,
            fromEmail: message.fromEmail,
            date: message.date,
            body: message.body,
            category: verdict.category,
            score: verdict.score,
            reasons: verdict.reasons,
            verdict: verdict.verdict,
          ),
        );
      }
      await MailDatabase.insertNew(fresh);

      // Only move the cursor once the rows are committed. A crash between the
      // two would otherwise skip the mail permanently.
      final highest = batch.highestUid;
      if (highest != null) {
        await SettingsStore.writeSyncCursor(
          SyncCursor(lastUid: highest, uidValidity: batch.uidValidity),
        );
      }

      var notified = 0;
      final notificationsOn = await SettingsStore.readNotificationsEnabled();
      if (allowNotifications && notificationsOn) {
        final pending = await MailDatabase.pendingNotifications();
        // Cap the burst. A first sync, or one after a long offline gap, can
        // find dozens of flagged mails at once; posting all of them buries the
        // shade and Android starts dropping them anyway. The newest are the
        // ones with deadlines still open, and the rest stay in the list.
        final toShow = pending.length <= maxNotificationsPerRun
            ? pending
            : pending.sublist(pending.length - maxNotificationsPerRun);
        for (final item in toShow) {
          await NotificationService.showMail(item);
        }
        await NotificationService.showSummary(toShow);
        await MailDatabase.markNotified(
          pending.map((MailItem item) => item.uid),
        );
        notified = toShow.length;
      }

      await MailDatabase.prune();
      await SettingsStore.writeLastSync(DateTime.now());
      await SettingsStore.writeLastError(null);

      var flagged = 0;
      var review = 0;
      var recruiter = 0;
      for (final item in fresh) {
        switch (item.verdict) {
          case MailVerdict.notify:
            flagged++;
          case MailVerdict.review:
            review++;
          case MailVerdict.informational:
            recruiter++;
          case MailVerdict.ignore:
          case MailVerdict.rejected:
            break;
        }
      }

      return SyncResult(
        fetched: batch.messages.length,
        added: fresh.length,
        flagged: flagged,
        needsReview: review,
        recruiter: recruiter,
        notified: notified,
        backlog: batch.totalNew - batch.messages.length,
        baseline: batch.baseline,
      );
    } on MailAuthException catch (error) {
      await SettingsStore.writeLastError(error.message);
      return SyncResult(error: error.message);
    } on Exception catch (error) {
      final message = error.toString();
      await SettingsStore.writeLastError(message);
      return SyncResult(error: message);
    }
  }

  /// Rescores the cached mail after a rules change, without going to the
  /// network. Returns how many rows changed verdict.
  static Future<int> reclassifyCached() async {
    final rules = await SettingsStore.readRules();
    final classifier = Classifier(rules);
    return MailDatabase.reclassifyAll(
      (MailItem item) => classifier.classify(
        subject: item.subject,
        body: item.body,
        fromEmail: item.fromEmail,
      ),
    );
  }
}
