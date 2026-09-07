import 'package:enough_mail/enough_mail.dart';

import 'credentials_store.dart';

/// A message as it came off the wire, before classification.
class FetchedMail {
  const FetchedMail({
    required this.uid,
    required this.messageId,
    required this.subject,
    required this.fromName,
    required this.fromEmail,
    required this.date,
    required this.body,
  });

  final int uid;
  final String messageId;
  final String subject;
  final String fromName;
  final String fromEmail;
  final DateTime date;

  /// Plain-text body, HTML-stripped and truncated. Only used for scoring.
  final String body;
}

/// The result of one fetch pass, including the cursor the next pass needs.
class FetchBatch {
  const FetchBatch({
    required this.messages,
    required this.uidValidity,
    required this.highestUid,
    required this.totalNew,
    required this.baseline,
    required this.bodiesBackfilled,
  });

  static const FetchBatch empty = FetchBatch(
    messages: <FetchedMail>[],
    uidValidity: null,
    highestUid: null,
    totalNew: 0,
    baseline: false,
    bodiesBackfilled: 0,
  );

  final List<FetchedMail> messages;

  /// The mailbox's UIDVALIDITY. If Gmail ever changes it, every stored UID is
  /// meaningless and the next sync has to start from a fresh baseline.
  final int? uidValidity;

  /// Highest UID actually processed, or `null` when nothing was. This is what
  /// the caller stores as the cursor.
  final int? highestUid;

  /// How many new messages the server had, before the per-run cap.
  final int totalNew;

  /// True when this pass ignored the cursor and re-read the newest messages,
  /// which happens on a first sync and after a UIDVALIDITY change.
  final bool baseline;

  /// How many messages needed a second round trip to get their text.
  final int bodiesBackfilled;
}

/// Raised when Gmail refuses the credentials, which in practice always means a
/// wrong or revoked App Password rather than a wrong mailbox.
class MailAuthException implements Exception {
  const MailAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Read-only Gmail access over IMAP using an App Password.
class ImapService {
  const ImapService._();

  static const String imapHost = 'imap.gmail.com';
  static const int imapPort = 993;

  /// SMTP settings are required by [MailAccount] but never used: this app only
  /// reads mail and never sends any.
  static const String _unusedSmtpHost = 'smtp.gmail.com';

  /// Messages larger than this arrive as envelope only on the first pass. They
  /// are not abandoned there — [_backfillBody] fetches their text parts in a
  /// second round trip, skipping attachments.
  static const int _downloadSizeLimit = 256 * 1024;

  /// Passed as `maxSize` when re-fetching an oversized message. Because every
  /// message that reaches that call is already above [_downloadSizeLimit],
  /// this always takes enough_mail's "non-attachment parts only" path, so a
  /// 20 MB mail with a PDF attached costs a few kilobytes of text.
  static const int _textPartSizeLimit = 128 * 1024;

  /// Most messages per sync that may pay for a second round trip. Bounds the
  /// worst case: a mailbox full of newsletters cannot stall a background run.
  static const int _maxBodyBackfills = 15;

  /// Longest we let a background sync sit on a socket. WorkManager gives a
  /// worker 10 minutes; failing fast leaves room for a retry.
  static const Duration _timeout = Duration(seconds: 45);

  /// How much body text the classifier ever sees. Beyond this it is quoted
  /// history and footers.
  static const int _bodyCharLimit = 6000;

  static MailClient _client(MailCredentials credentials) => MailClient(
    MailAccount.fromManualSettings(
      name: 'gmail',
      email: credentials.email,
      incomingHost: imapHost,
      outgoingHost: _unusedSmtpHost,
      password: credentials.appPassword,
      incomingPort: imapPort,
      incomingSocketType: SocketType.ssl,
    ),
    downloadSizeLimit: _downloadSizeLimit,
  );

  /// Connects and selects the INBOX, then disconnects. Used by the login screen
  /// so bad credentials are caught before they are stored.
  static Future<void> verify(MailCredentials credentials) async {
    final client = _client(credentials);
    try {
      await client.connect(timeout: _timeout);
      await client.selectInbox();
    } on MailException catch (error) {
      throw MailAuthException(_describe(error));
    } finally {
      await _safeDisconnect(client);
    }
  }

  /// Fetches only the messages that arrived after [sinceUid].
  ///
  /// This is the whole efficiency story of the app. Re-reading the newest N
  /// messages on every run meant downloading tens of full messages every
  /// 15 minutes to discover, almost always, that nothing had changed. IMAP
  /// UIDs only ever increase within a mailbox, so the highest UID already
  /// stored is a valid cursor:
  ///
  ///  * when the mailbox's UIDVALIDITY still matches, `UID FETCH <cursor+1>:*`
  ///    returns exactly the new mail;
  ///  * when UIDNEXT proves nothing has arrived, no FETCH is issued at all and
  ///    the pass costs one SELECT;
  ///  * when the cursor is missing or UIDVALIDITY changed, it falls back to the
  ///    newest [baselineCount] messages.
  ///
  /// At most [maxMessages] are returned, oldest first, so that a large backlog
  /// is worked through over several runs instead of being dropped.
  static Future<FetchBatch> fetchNew({
    required MailCredentials credentials,
    required int? sinceUid,
    required int? uidValidity,
    required int baselineCount,
    required int maxMessages,
  }) async {
    final client = _client(credentials);
    try {
      await client.connect(timeout: _timeout);
      final inbox = await client.selectInbox();
      final validity = inbox.uidValidity;
      final uidNext = inbox.uidNext;

      // Promoted to non-null only when the stored cursor is still meaningful.
      final int? cursor =
          sinceUid != null && uidValidity != null && uidValidity == validity
          ? sinceUid
          : null;

      var baseline = false;
      List<MimeMessage> raw;
      if (cursor == null) {
        baseline = true;
        raw = await client.fetchMessages(
          count: baselineCount,
          fetchPreference: FetchPreference.fullWhenWithinSize,
        );
      } else if (uidNext != null && uidNext <= cursor + 1) {
        raw = const <MimeMessage>[];
      } else {
        raw = await client.fetchMessageSequence(
          MessageSequence.fromRangeToLast(cursor + 1, isUidSequence: true),
          fetchPreference: FetchPreference.fullWhenWithinSize,
        );
        // A `n:*` sequence still returns the last message when its UID is
        // below n, so the range has to be enforced here as well.
        raw = raw
            .where((MimeMessage m) => (m.uid ?? 0) > cursor)
            .toList(growable: false);
      }

      final ordered = raw.toList()
        ..sort(
          (MimeMessage a, MimeMessage b) =>
              (a.uid ?? 0).compareTo(b.uid ?? 0),
        );
      final capped = ordered.length <= maxMessages
          ? ordered
          : ordered.sublist(0, maxMessages);

      final fetched = <FetchedMail>[];
      var backfilled = 0;
      int? highest;
      for (final message in capped) {
        final uid = message.uid;
        if (uid == null) continue;
        var mime = message;
        if (_textOf(mime).trim().isEmpty && backfilled < _maxBodyBackfills) {
          backfilled++;
          mime = await _backfillBody(client, mime);
        }
        fetched.add(_convert(mime, uid));
        highest = highest == null || uid > highest ? uid : highest;
      }

      // A baseline that found nothing still has to move the cursor forward, or
      // every later run would re-baseline.
      if (highest == null && baseline && uidNext != null && uidNext > 1) {
        highest = uidNext - 1;
      }

      fetched.sort((FetchedMail a, FetchedMail b) => b.date.compareTo(a.date));
      return FetchBatch(
        messages: fetched,
        uidValidity: validity,
        highestUid: highest,
        totalNew: ordered.length,
        baseline: baseline,
        bodiesBackfilled: backfilled,
      );
    } on MailException catch (error) {
      throw MailAuthException(_describe(error));
    } finally {
      await _safeDisconnect(client);
    }
  }

  /// Second round trip for a message too large to have been downloaded whole.
  ///
  /// Without this, every mail over the size limit was scored on its subject
  /// line alone — and HTML recruiting mail with an image signature routinely
  /// crosses that limit, which is exactly how real interview invitations went
  /// unnoticed.
  static Future<MimeMessage> _backfillBody(
    MailClient client,
    MimeMessage message,
  ) async {
    try {
      return await client.fetchMessageContents(
        message,
        maxSize: _textPartSizeLimit,
        includedInlineTypes: <MediaToptype>[MediaToptype.text],
        responseTimeout: _timeout,
      );
    } on MailException {
      // Leave it envelope-only rather than failing the whole sync: the subject
      // still gets scored, and the next run will not retry a stored message.
      return message;
    }
  }

  /// Plain text if the message has any, otherwise the HTML with its markup
  /// stripped.
  static String _textOf(MimeMessage message) {
    final plain = message.decodeTextPlainPart();
    if (plain != null && plain.trim().isNotEmpty) return plain;
    return stripHtml(message.decodeTextHtmlPart() ?? '');
  }

  static FetchedMail _convert(MimeMessage message, int uid) {
    final sender = message.from?.isNotEmpty == true
        ? message.from!.first
        : message.sender;

    return FetchedMail(
      uid: uid,
      messageId: message.getHeaderValue('message-id') ?? '',
      subject: message.decodeSubject() ?? '(no subject)',
      fromName: sender?.personalName ?? '',
      fromEmail: sender?.email ?? message.fromEmail ?? '',
      date: message.decodeDate() ?? DateTime.now(),
      body: _truncate(_textOf(message), _bodyCharLimit),
    );
  }

  /// Crude but sufficient: the classifier only needs word content, not
  /// structure, and a real HTML parser would be dead weight here.
  static String stripHtml(String html) => html
      .replaceAll(
        RegExp(
          r'<(script|style|head)[^>]*>.*?</\1>',
          dotAll: true,
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      // Curly quotes and dashes arrive as numeric entities in mail written in
      // Word or Outlook. Left in place they split a phrase in two.
      .replaceAll(RegExp(r'&#\d+;'), ' ')
      .replaceAll(RegExp(r'&[a-zA-Z]+;'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _truncate(String input, int limit) =>
      input.length <= limit ? input : input.substring(0, limit);

  static String _describe(MailException error) {
    final detail = error.message ?? error.toString();
    final lower = detail.toLowerCase();
    if (lower.contains('authenticationfailed') ||
        lower.contains('invalid credentials') ||
        lower.contains('login failed') ||
        lower.contains('authentication failed')) {
      return 'Gmail rejected the login. Check the email address and generate a '
          'fresh App Password (the 16-character one, not your Google password).';
    }
    if (lower.contains('timeout') || lower.contains('socket')) {
      return 'Could not reach imap.gmail.com. Check the network connection.';
    }
    return detail;
  }

  static Future<void> _safeDisconnect(MailClient client) async {
    try {
      await client.disconnect();
    } on Exception {
      // Disconnect failures are irrelevant: the work is already done and the
      // socket is torn down by the OS either way.
    }
  }
}
