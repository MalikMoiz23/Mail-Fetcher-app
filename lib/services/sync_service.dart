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
    this.notified = 0,
    this.error,
    this.notConfigured = false,
  });

  final int fetched;
  final int added;

  /// New mail that earned a notification.
  final int flagged;

  /// New mail listed for review but not notified.
  final int needsReview;

  final int notified;
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

  static Future<SyncResult> run({required bool allowNotifications}) async {
    try {
      final credentials = await CredentialsStore.read();
      if (credentials == null) {
        return const SyncResult(notConfigured: true);
      }

      final rules = await SettingsStore.readRules();
      final fetchCount = await SettingsStore.readFetchCount();
      final classifier = Classifier(rules);

      final messages = await ImapService.fetchRecent(
        credentials: credentials,
        count: fetchCount,
      );

      final known = await MailDatabase.knownUids();
      final fresh = <MailItem>[];
      for (final message in messages) {
        if (known.contains(message.uid)) continue;
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
        await MailDatabase.markNotified(
          pending.map((MailItem item) => item.uid),
        );
        notified = toShow.length;
      }

      await MailDatabase.prune();
      await SettingsStore.writeLastSync(DateTime.now());
      await SettingsStore.writeLastError(null);

      return SyncResult(
        fetched: messages.length,
        added: fresh.length,
        flagged: fresh
            .where((MailItem item) => item.verdict == MailVerdict.notify)
            .length,
        needsReview: fresh
            .where((MailItem item) => item.verdict == MailVerdict.review)
            .length,
        notified: notified,
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
