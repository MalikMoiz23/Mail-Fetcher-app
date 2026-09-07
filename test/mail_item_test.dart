import 'package:flutter_test/flutter_test.dart';
import 'package:mail_fetching_app/models/mail_item.dart';

MailItem item({
  int uid = 1,
  String messageId = '<abc123@mail.gmail.com>',
  String body = 'hello',
  String fromName = 'Acme Recruiting',
  MailVerdict verdict = MailVerdict.notify,
  MailCategory category = MailCategory.interview,
}) => MailItem(
  uid: uid,
  messageId: messageId,
  subject: 'Interview invitation',
  fromName: fromName,
  fromEmail: 'jobs@acme.com',
  date: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  body: body,
  category: category,
  score: 20,
  reasons: const <String>['+20  "interview invitation" in subject — Interview'],
  verdict: verdict,
);

void main() {
  test('survives a database round trip', () {
    final original = item();
    final restored = MailItem.fromMap(original.toMap());
    expect(restored.uid, original.uid);
    expect(restored.subject, original.subject);
    expect(restored.category, original.category);
    expect(restored.verdict, original.verdict);
    expect(restored.score, original.score);
    expect(restored.reasons, original.reasons);
    expect(restored.date, original.date);
    expect(restored.body, original.body);
  });

  test('every verdict round trips', () {
    for (final verdict in MailVerdict.values) {
      final restored = MailItem.fromMap(item(verdict: verdict).toMap());
      expect(restored.verdict, verdict);
    }
  });

  test('an unknown stored verdict degrades to ignore, not a crash', () {
    final map = item().toMap()..['verdict'] = 'removed_in_a_later_version';
    expect(MailItem.fromMap(map).verdict, MailVerdict.ignore);
  });

  test('only the notify verdict is notifiable', () {
    expect(item(verdict: MailVerdict.notify).shouldNotify, isTrue);
    for (final verdict in MailVerdict.values.where(
      (MailVerdict v) => v != MailVerdict.notify,
    )) {
      expect(
        item(verdict: verdict).shouldNotify,
        isFalse,
        reason: '$verdict must never reach the notification shade',
      );
    }
  });

  test('recruiter mail is labelled by its verdict, not its category', () {
    expect(
      item(
        verdict: MailVerdict.informational,
        category: MailCategory.recruiter,
      ).displayLabel,
      'Recruiter',
    );
  });

  test('the row label reports the verdict when it matters more', () {
    expect(
      item(verdict: MailVerdict.notify, category: MailCategory.offer)
          .displayLabel,
      'Job offer',
    );
    // A review item's category is usually meaningless, so the verdict is the
    // more informative label.
    expect(
      item(verdict: MailVerdict.review, category: MailCategory.other)
          .displayLabel,
      'Needs review',
    );
    expect(
      item(verdict: MailVerdict.rejected, category: MailCategory.interview)
          .displayLabel,
      'Rejection',
    );
  });

  test('an empty reasons list does not become a list containing ""', () {
    final stored = MailItem.fromMap(
      MailItem(
        uid: 2,
        messageId: '',
        subject: 's',
        fromName: '',
        fromEmail: 'a@b.com',
        date: DateTime.fromMillisecondsSinceEpoch(0),
        body: '',
        category: MailCategory.other,
        score: 0,
        reasons: const <String>[],
        verdict: MailVerdict.ignore,
      ).toMap(),
    );
    expect(stored.reasons, isEmpty);
  });

  test('notification ids stay inside the signed 32-bit range', () {
    expect(item(uid: 4294967295).notificationId, lessThan(2147483647));
    expect(item(uid: 4294967295).notificationId, greaterThanOrEqualTo(0));
  });

  test('gmail link uses rfc822msgid and drops the angle brackets', () {
    final link = item().gmailLink;
    expect(link, isNotNull);
    expect(link, contains('rfc822msgid'));
    expect(link, isNot(contains('<')));
    expect(link, contains(Uri.encodeComponent('abc123@mail.gmail.com')));
  });

  test('no Message-ID means no link rather than a broken one', () {
    expect(item(messageId: '').gmailLink, isNull);
    expect(item(messageId: '<>').gmailLink, isNull);
  });

  test('snippet collapses whitespace and truncates', () {
    expect(item(body: 'a\n\n  b\tc').snippet, 'a b c');
    final long = item(body: 'x' * 1000).snippet;
    expect(long.length, MailItem.snippetLength + 1);
    expect(long.endsWith('…'), isTrue);
  });

  test('displayFrom falls back to the address when there is no name', () {
    expect(item().displayFrom, 'Acme Recruiting');
    expect(item(fromName: '').displayFrom, 'jobs@acme.com');
  });
}
