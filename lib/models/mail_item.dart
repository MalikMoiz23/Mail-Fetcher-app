/// What the app should DO about a message, as distinct from what the message
/// is about (see [MailCategory]).
///
/// The tiers exist because precision and completeness pull in opposite
/// directions: notifications must be trustworthy, but a vaguely worded real
/// invitation must not vanish silently either.
enum MailVerdict {
  /// Decisive wording found. Listed and pushed as a notification.
  notify('Flagged'),

  /// Supporting signals only — a scheduling link, "your availability" — with no
  /// decisive interview or offer wording. Listed under "Needs review" so it can
  /// be checked deliberately, never notified.
  review('Needs review'),

  /// Demonstrably about employment, but nothing is being asked of the reader:
  /// cold outreach, "we received your application", job-alert digests. Listed
  /// under its own filter and structurally incapable of notifying.
  informational('Recruiter'),

  /// Nothing meaningful matched. Only visible via "Show everything".
  ignore('Ignored'),

  /// Rejection wording vetoed it.
  rejected('Rejection');

  const MailVerdict(this.label);

  final String label;

  static MailVerdict byName(String name) => MailVerdict.values.firstWhere(
    (verdict) => verdict.name == name,
    orElse: () => MailVerdict.ignore,
  );

  /// Verdicts that appear in the default list. Recruiter mail is excluded on
  /// purpose: it is high volume and needs no decision, so it lives behind its
  /// own filter instead of diluting the list that matters.
  static const Set<MailVerdict> listedByDefault = <MailVerdict>{notify, review};

  /// The only verdict that may ever reach the notification shade.
  static const Set<MailVerdict> notifiable = <MailVerdict>{notify};
}

/// What a message is about.
///
/// [priority] decides which label wins when several rule groups match: an email
/// that mentions both an offer and an interview is an offer.
enum MailCategory {
  offer('Job offer', 5),
  interview('Interview', 4),
  assessment('Assessment', 3),
  recruiter('Recruiter', 2),
  rejection('Rejection', 1),
  other('Other', 0);

  const MailCategory(this.label, this.priority);

  final String label;
  final int priority;

  static MailCategory byName(String name) => MailCategory.values.firstWhere(
    (category) => category.name == name,
    orElse: () => MailCategory.other,
  );

  /// Categories that describe something the reader has to act on, and which
  /// therefore may notify. Recruiter outreach is deliberately absent.
  static const Set<MailCategory> actionable = <MailCategory>{
    offer,
    interview,
    assessment,
  };
}

/// A fetched message plus the verdict the classifier reached about it.
class MailItem {
  const MailItem({
    required this.uid,
    required this.messageId,
    required this.subject,
    required this.fromName,
    required this.fromEmail,
    required this.date,
    required this.body,
    required this.category,
    required this.score,
    required this.reasons,
    required this.verdict,
    this.notified = false,
    this.archived = false,
    this.userOverride = false,
  });

  factory MailItem.fromMap(Map<String, Object?> map) => MailItem(
    uid: map['uid']! as int,
    messageId: map['message_id']! as String,
    subject: map['subject']! as String,
    fromName: map['from_name']! as String,
    fromEmail: map['from_email']! as String,
    date: DateTime.fromMillisecondsSinceEpoch(map['date_ms']! as int),
    body: map['body']! as String,
    category: MailCategory.byName(map['category']! as String),
    score: map['score']! as int,
    reasons: (map['reasons']! as String).isEmpty
        ? const <String>[]
        : (map['reasons']! as String).split('\n'),
    verdict: MailVerdict.byName(map['verdict']! as String),
    notified: (map['notified']! as int) == 1,
    archived: (map['archived']! as int) == 1,
    userOverride: (map['user_override']! as int) == 1,
  );

  /// IMAP UID within the INBOX. Stable for the lifetime of the mailbox, which
  /// is what makes it usable as the primary key, as the notification id and as
  /// the sync cursor.
  final int uid;

  /// RFC 822 Message-ID, used to build a Gmail deep link. Empty if absent.
  final String messageId;

  final String subject;
  final String fromName;
  final String fromEmail;
  final DateTime date;

  /// Plain-text body as the classifier saw it, HTML-stripped and truncated.
  /// Kept in full (not just as a preview) so that editing the rules can rescore
  /// cached mail with exactly the same input as the original pass.
  final String body;

  final MailCategory category;
  final int score;

  /// Human-readable explanation of every rule that fired, so a verdict can be
  /// audited instead of trusted blindly.
  final List<String> reasons;

  final MailVerdict verdict;
  final bool notified;
  final bool archived;

  /// Set once the user has manually corrected the verdict. Re-classification
  /// leaves such rows alone.
  final bool userOverride;

  bool get shouldNotify => MailVerdict.notifiable.contains(verdict);

  /// Notification ids must fit in a signed 32-bit int on Android.
  int get notificationId => uid % 2147483647;

  String get displayFrom => fromName.isEmpty ? fromEmail : fromName;

  /// Label to show on the row. A "Needs review" mail usually has no category
  /// worth naming, so the verdict is the more informative of the two.
  String get displayLabel => switch (verdict) {
    MailVerdict.review => MailVerdict.review.label,
    MailVerdict.informational => MailCategory.recruiter.label,
    MailVerdict.rejected => MailCategory.rejection.label,
    _ => category.label,
  };

  /// Short preview for list rows and notification text.
  String get snippet {
    final collapsed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= snippetLength) return collapsed;
    return '${collapsed.substring(0, snippetLength)}…';
  }

  static const int snippetLength = 300;

  /// Lower-cased text the in-app search runs against.
  String get searchHaystack =>
      '$subject $fromName $fromEmail $body'.toLowerCase();

  /// Gmail web/app deep link that resolves the exact message, or `null` when
  /// the server gave us no Message-ID.
  String? get gmailLink {
    final trimmed = messageId.replaceAll(RegExp(r'[<>]'), '').trim();
    if (trimmed.isEmpty) return null;
    return 'https://mail.google.com/mail/u/0/#search/'
        '${Uri.encodeComponent('rfc822msgid:$trimmed')}';
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'uid': uid,
    'message_id': messageId,
    'subject': subject,
    'from_name': fromName,
    'from_email': fromEmail,
    'date_ms': date.millisecondsSinceEpoch,
    'body': body,
    'category': category.name,
    'score': score,
    'reasons': reasons.join('\n'),
    'verdict': verdict.name,
    'notified': notified ? 1 : 0,
    'archived': archived ? 1 : 0,
    'user_override': userOverride ? 1 : 0,
  };

  MailItem copyWith({
    MailCategory? category,
    int? score,
    List<String>? reasons,
    MailVerdict? verdict,
    bool? notified,
    bool? archived,
    bool? userOverride,
  }) => MailItem(
    uid: uid,
    messageId: messageId,
    subject: subject,
    fromName: fromName,
    fromEmail: fromEmail,
    date: date,
    body: body,
    category: category ?? this.category,
    score: score ?? this.score,
    reasons: reasons ?? this.reasons,
    verdict: verdict ?? this.verdict,
    notified: notified ?? this.notified,
    archived: archived ?? this.archived,
    userOverride: userOverride ?? this.userOverride,
  );
}
