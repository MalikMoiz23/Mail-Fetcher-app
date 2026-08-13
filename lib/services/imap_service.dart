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

  /// Messages larger than this are fetched as envelope only (subject, sender,
  /// date). Keeps a background sync off mobile-data-heavy newsletters while
  /// still classifying their subject lines.
  static const int _downloadSizeLimit = 128 * 1024;

  /// Longest we let a background sync sit on a socket. WorkManager gives a
  /// worker 10 minutes; failing fast leaves room for a retry.
  static const Duration _timeout = Duration(seconds: 45);

  /// How much body text the classifier ever sees. Beyond this it is quoted
  /// history and footers.
  static const int _bodyCharLimit = 4000;

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

  /// Fetches the newest [count] INBOX messages, newest first.
  static Future<List<FetchedMail>> fetchRecent({
    required MailCredentials credentials,
    required int count,
  }) async {
    final client = _client(credentials);
    try {
      await client.connect(timeout: _timeout);
      await client.selectInbox();
      // page 1 of MessageSequence.fromPage is an open-ended range ending at the
      // last message, so this is the newest `count` messages.
      final messages = await client.fetchMessages(
        count: count,
        fetchPreference: FetchPreference.fullWhenWithinSize,
      );
      final fetched = <FetchedMail>[];
      for (final message in messages) {
        final mail = _convert(message);
        if (mail != null) fetched.add(mail);
      }
      fetched.sort((a, b) => b.date.compareTo(a.date));
      return fetched;
    } on MailException catch (error) {
      throw MailAuthException(_describe(error));
    } finally {
      await _safeDisconnect(client);
    }
  }

  /// Returns `null` when the server gave us no UID, which would leave the row
  /// without a stable primary key and risk duplicate notifications.
  static FetchedMail? _convert(MimeMessage message) {
    final uid = message.uid;
    if (uid == null) return null;

    final sender = message.from?.isNotEmpty == true
        ? message.from!.first
        : message.sender;

    final plain = message.decodeTextPlainPart();
    final body = plain != null && plain.trim().isNotEmpty
        ? plain
        : stripHtml(message.decodeTextHtmlPart() ?? '');

    return FetchedMail(
      uid: uid,
      messageId: message.getHeaderValue('message-id') ?? '',
      subject: message.decodeSubject() ?? '(no subject)',
      fromName: sender?.personalName ?? '',
      fromEmail: sender?.email ?? message.fromEmail ?? '',
      date: message.decodeDate() ?? DateTime.now(),
      body: _truncate(body, _bodyCharLimit),
    );
  }

  /// Crude but sufficient: the classifier only needs word content, not
  /// structure, and a real HTML parser would be dead weight here.
  static String stripHtml(String html) => html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
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
