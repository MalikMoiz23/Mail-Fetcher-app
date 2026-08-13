import '../models/mail_item.dart';
import '../models/rule_set.dart';

/// Verdict for a single message.
class Classification {
  const Classification({
    required this.category,
    required this.score,
    required this.reasons,
    required this.verdict,
  });

  final MailCategory category;
  final int score;
  final List<String> reasons;
  final MailVerdict verdict;

  bool get shouldNotify => verdict == MailVerdict.notify;
}

/// Rule-based importance scoring, on device.
///
/// The engine is tiered rather than purely additive. A plain sum lets weak
/// signals conspire: "your application" plus a greenhouse.io sender plus the
/// word "position" used to be enough to notify about an automated
/// acknowledgement containing no interview and no offer.
///
/// A notification now requires one of:
///  * an **anchor** match — wording that can only mean an interview, an offer or
///    an assessment; or
///  * two distinct **support** matches together with job context — one vague
///    signal is noise, two independent ones in a mail that is demonstrably about
///    employment is a pattern.
///
/// Anything with weaker evidence is listed under "Needs review" instead, so a
/// vaguely worded real invitation is never silently dropped.
///
/// Phrase matching anchors at the start of a word only, so "interview" also
/// catches "interviews" and "interviewing".
class Classifier {
  Classifier(this.rules);

  final RuleSet rules;

  final Map<String, RegExp> _cache = <String, RegExp>{};

  /// Collapses everything that is not a letter or digit into single spaces so
  /// that phrases match across punctuation, line breaks and HTML leftovers.
  static String normalize(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  RegExp _matcher(String normalizedPhrase) => _cache.putIfAbsent(
    normalizedPhrase,
    () => RegExp('(?<![a-z0-9])${RegExp.escape(normalizedPhrase)}'),
  );

  bool _matches(String normalizedPhrase, String haystack) =>
      _matcher(normalizedPhrase).hasMatch(haystack);

  /// True when [host] equals [domain] or is a subdomain of it.
  static bool _hostMatches(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  Classification classify({
    required String subject,
    required String body,
    required String fromEmail,
  }) {
    final normalizedSubject = normalize(subject);
    final normalizedBody = normalize(body);
    final sender = fromEmail.toLowerCase().trim();
    final host = sender.contains('@') ? sender.split('@').last : sender;

    for (final muted in rules.mutedSenders) {
      final needle = muted.toLowerCase().trim();
      if (needle.isNotEmpty && sender.contains(needle)) {
        return Classification(
          category: MailCategory.other,
          score: 0,
          reasons: <String>['Muted sender: address contains "$needle"'],
          verdict: MailVerdict.ignore,
        );
      }
    }

    var score = 0;
    final reasons = <String>[];
    final matchedCategories = <MailCategory>[];

    var anchorMatched = false;
    var offerAnchorMatched = false;
    var supportMatches = 0;
    var supportMatched = false;
    var contextMatched = false;

    for (final spec in kRuleGroups) {
      final tier = rules.tierOf(spec.id);
      final phrases = rules.groups[spec.id] ?? const <String>[];
      var groupMatched = false;

      for (final phrase in phrases) {
        final normalizedPhrase = normalize(phrase);
        if (normalizedPhrase.isEmpty) continue;

        // Subject hits outrank body hits: senders put the point of the mail in
        // the subject, while bodies carry boilerplate and quoted history.
        final inSubject = _matches(normalizedPhrase, normalizedSubject);
        final inBody = _matches(normalizedPhrase, normalizedBody);
        if (!inSubject && !inBody) continue;

        groupMatched = true;
        if (tier == RuleGroupTier.support) supportMatches++;

        if (inSubject) {
          final points = spec.weight * RuleSet.subjectMultiplier;
          score += points;
          reasons.add('+$points  "$phrase" in subject — ${spec.label}');
        }
        if (inBody) {
          score += spec.weight;
          reasons.add('+${spec.weight}  "$phrase" in body — ${spec.label}');
        }
      }

      if (!groupMatched) continue;

      switch (tier) {
        case RuleGroupTier.anchor:
          anchorMatched = true;
          if (spec.id == 'offer') offerAnchorMatched = true;
        case RuleGroupTier.support:
          supportMatched = true;
        case RuleGroupTier.weak:
          contextMatched = true;
      }
      final category = spec.category;
      if (category != null) matchedCategories.add(category);
    }

    // Video and AI interview platforms count as an anchor: receiving mail from
    // one means an interview task has been assigned, whatever the wording.
    for (final domain in rules.interviewPlatformDomains) {
      final needle = domain.toLowerCase().trim();
      if (needle.isEmpty || !_hostMatches(host, needle)) continue;
      score += RuleSet.interviewPlatformWeight;
      anchorMatched = true;
      matchedCategories.add(MailCategory.interview);
      reasons.add(
        '+${RuleSet.interviewPlatformWeight}  sender is the interview '
        'platform "$needle"',
      );
      break;
    }

    for (final domain in rules.senderDomains) {
      final needle = domain.toLowerCase().trim();
      if (needle.isEmpty || !_hostMatches(host, needle)) continue;
      score += RuleSet.senderDomainWeight;
      contextMatched = true;
      reasons.add(
        '+${RuleSet.senderDomainWeight}  sender domain "$needle" is a hiring '
        'platform',
      );
      break;
    }

    final rejectionHits = <String>[];
    for (final phrase in rules.rejectionPhrases) {
      final normalizedPhrase = normalize(phrase);
      if (normalizedPhrase.isEmpty) continue;
      if (_matches(normalizedPhrase, normalizedSubject) ||
          _matches(normalizedPhrase, normalizedBody)) {
        rejectionHits.add(phrase);
      }
    }

    // A rejection veto is only safe when no offer wording is present: offer
    // mails routinely recap the process ("we interviewed other candidates").
    if (rejectionHits.isNotEmpty && !offerAnchorMatched) {
      return Classification(
        category: MailCategory.rejection,
        score: score,
        reasons: <String>[
          ...reasons,
          'Rejection wording: ${rejectionHits.map((p) => '"$p"').join(', ')}',
          'Suppressed — rejection wording with no offer wording to override it.',
        ],
        verdict: MailVerdict.rejected,
      );
    }

    matchedCategories.sort(
      (MailCategory a, MailCategory b) => b.priority.compareTo(a.priority),
    );
    final category = matchedCategories.isEmpty
        ? MailCategory.other
        : matchedCategories.first;

    final promotedBySupport =
        supportMatches >= RuleSet.supportMatchesForNotify && contextMatched;

    if (anchorMatched) {
      reasons.add('Decisive wording found (an anchor phrase matched).');
    } else if (promotedBySupport) {
      reasons.add(
        '$supportMatches separate ambiguous signals plus job wording — treated '
        'as decisive.',
      );
    } else if (supportMatched) {
      reasons.add(
        'Only ambiguous wording matched, so this is listed for review rather '
        'than notified.',
      );
    } else {
      reasons.add('No decisive or ambiguous wording matched.');
    }

    final MailVerdict verdict;
    if ((anchorMatched || promotedBySupport) &&
        score >= rules.notifyThreshold) {
      verdict = MailVerdict.notify;
      reasons.add(
        'Score $score >= notify threshold ${rules.notifyThreshold} → notify',
      );
    } else if ((anchorMatched || supportMatched) &&
        score >= rules.reviewThreshold) {
      verdict = MailVerdict.review;
      reasons.add(
        'Score $score >= review threshold ${rules.reviewThreshold} but short of '
        'the notify bar → needs review',
      );
    } else {
      verdict = MailVerdict.ignore;
      reasons.add(
        'Score $score < review threshold ${rules.reviewThreshold} → ignored',
      );
    }

    return Classification(
      category: category,
      score: score,
      reasons: reasons,
      verdict: verdict,
    );
  }
}
