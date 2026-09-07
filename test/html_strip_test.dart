import 'package:flutter_test/flutter_test.dart';
import 'package:mail_fetching_app/models/mail_item.dart';
import 'package:mail_fetching_app/models/rule_set.dart';
import 'package:mail_fetching_app/services/classifier.dart';
import 'package:mail_fetching_app/services/imap_service.dart';

/// Most recruiting mail is HTML-only. If the strip step loses the wording, the
/// classifier never sees it, so this is on the critical path.
void main() {
  test('drops tags but keeps the words', () {
    final text = ImapService.stripHtml(
      '<div><p>Please confirm <b>your availability</b> for a call.</p></div>',
    );
    expect(text, 'Please confirm your availability for a call.');
  });

  test('drops script and style contents entirely', () {
    final text = ImapService.stripHtml(
      '<style>.x{color:red}</style><script>var a=1;</script><p>Interview</p>',
    );
    expect(text, 'Interview');
    expect(text, isNot(contains('color')));
    expect(text, isNot(contains('var')));
  });

  test('handles uppercase and attributed tags', () {
    final text = ImapService.stripHtml(
      '<SCRIPT type="text/javascript">bad()</SCRIPT><SPAN>Offer letter</SPAN>',
    );
    expect(text, 'Offer letter');
  });

  test('decodes the entities that actually appear in mail', () {
    expect(
      ImapService.stripHtml('Acme&nbsp;&amp;&nbsp;Co &lt;hr&gt; &quot;x&quot;'),
      'Acme & Co <hr> "x"',
    );
  });

  test('an HTML-only interview invite still classifies as one', () {
    final body = ImapService.stripHtml(
      '<html><body><table><tr><td>'
      '<p>Hi,</p><p>We would like to <strong>schedule an interview</strong> '
      'with you. Book a slot at '
      '<a href="https://calendly.com/acme">this link</a>.</p>'
      '</td></tr></table></body></html>',
    );
    final result = Classifier(RuleSet.defaults).classify(
      subject: 'Next steps at Acme',
      body: body,
      fromEmail: 'hiring@acme.com',
    );
    expect(result.verdict, MailVerdict.notify);
  });

  test('numeric and named entities do not split a phrase in two', () {
    // Mail written in Outlook or Word is full of curly quotes and dashes
    // encoded as entities. Left in place they break phrase matching.
    final text = ImapService.stripHtml(
      '<p>We&rsquo;d like to schedule an&#8201;interview with you.</p>',
    );
    final result = Classifier(RuleSet.defaults).classify(
      subject: 'Acme',
      body: text,
      fromEmail: 'hiring@acme.com',
    );
    expect(result.verdict, MailVerdict.notify);
  });

  test('comments and head blocks are dropped', () {
    expect(
      ImapService.stripHtml(
        '<head><title>x</title></head><!--[if mso]>junk<![endif]--><p>Offer '
        'letter</p>',
      ),
      'Offer letter',
    );
  });

  test('unclosed and malformed tags do not swallow the text', () {
    // Real mail contains broken markup; losing the body here would silently
    // downgrade the mail to subject-only scoring.
    expect(ImapService.stripHtml('<p>Interview<p>tomorrow'), 'Interview tomorrow');
  });
}
