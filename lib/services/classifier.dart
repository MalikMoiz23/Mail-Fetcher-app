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

  bool get shouldNotify => MailVerdict.notifiable.contains(verdict);
}

/// One phrase, normalised once when the rules are loaded rather than once per
/// message. A phrase list of ~400 entries is walked for every mail, so
/// normalising inside the hot loop dominated the cost of a sync.
class _Phrase {
  _Phrase(this.original, this.normalized) : spaced = ' $normalized';

  final String original;
  final String normalized;

  /// The phrase with a leading space, precomputed so that matching allocates
  /// nothing at all.
  final String spaced;
}

class _Group {
  const _Group(this.spec, this.tier, this.phrases);

  final RuleGroupSpec spec;
  final RuleGroupTier tier;
  final List<_Phrase> phrases;
}

/// Rule-based importance scoring, on device.
///
/// The engine is tiered rather than purely additive. A plain sum lets weak
/// signals conspire: "your application" plus a greenhouse.io sender plus the
/// word "position" used to be enough to notify about an automated
/// acknowledgement containing no interview and no offer.
///
/// A notification requires **decisive** wording, which means one of:
///  * an anchor match — wording that can only mean an interview, an offer or an
///    assessment;
///  * mail from a video or AI interview platform, which is an interview task by
///    definition; or
///  * ambiguous interview wording ("Interview with Acme") backed by both
///    scheduling wording and job wording.
///
/// Three things can then take a notification away again:
///  * rejection wording, unless offer wording overrides it;
///  * job-alert or marketing wording, unless the decisive phrase is in the
///    subject line — digests quote job descriptions verbatim, so their bodies
///    contain other people's interview invitations;
///  * recruiter wording with nothing decisive of its own, which is filed under
///    "Recruiter" and can never notify however much it scores.
///
/// Anything with weaker evidence is listed under "Needs review" instead, so a
/// vaguely worded real invitation is never silently dropped.
///
/// Phrase matching anchors at the start of a word only, so "interview" also
/// catches "interviews" and "interviewing".
class Classifier {
  Classifier(this.rules) : _groups = _compile(rules);

  final RuleSet rules;
  final List<_Group> _groups;

  static List<_Group> _compile(RuleSet rules) => <_Group>[
    for (final spec in kRuleGroups)
      _Group(spec, rules.tierOf(spec.id), <_Phrase>[
        for (final phrase in rules.phrasesOf(spec.id))
          if (normalize(phrase).isNotEmpty) _Phrase(phrase, normalize(phrase)),
      ]),
  ];

  /// Collapses everything that is not a letter or digit into single spaces so
  /// that phrases match across punctuation, line breaks and HTML leftovers.
  static String normalize(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// True when [haystack] contains [phrase] at a word start.
  ///
  /// Both sides are normalised, so the only character that can precede a word
  /// is a single space. That makes this equivalent to the `(?<![a-z0-9])`
  /// regex it replaces, without compiling or running one per phrase.
  static bool _matches(_Phrase phrase, String haystack) =>
      haystack.startsWith(phrase.normalized) ||
      haystack.contains(phrase.spaced);

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
    final matchedGroups = <String>{};

    var anchorMatched = false;
    var anchorInSubject = false;
    var offerAnchorMatched = false;
    var supportMatched = false;
    var recruiterMatched = false;
    var digestMatched = false;
    var decisiveSender = false;

    for (final group in _groups) {
      final spec = group.spec;
      var groupMatched = false;
      var groupInSubject = false;

      for (final phrase in group.phrases) {
        // Subject hits outrank body hits: senders put the point of the mail in
        // the subject, while bodies carry boilerplate and quoted history.
        final inSubject = _matches(phrase, normalizedSubject);
        final inBody = _matches(phrase, normalizedBody);
        if (!inSubject && !inBody) continue;

        groupMatched = true;
        groupInSubject |= inSubject;

        if (spec.weight == 0) {
          reasons.add(
            '  "${phrase.original}" in ${inSubject ? 'subject' : 'body'} — '
            '${spec.label}',
          );
          continue;
        }
        if (inSubject) {
          final points = spec.weight * RuleSet.subjectMultiplier;
          score += points;
          reasons.add('+$points  "${phrase.original}" in subject — '
              '${spec.label}');
        }
        if (inBody) {
          score += spec.weight;
          reasons.add('+${spec.weight}  "${phrase.original}" in body — '
              '${spec.label}');
        }
      }

      if (!groupMatched) continue;
      matchedGroups.add(spec.id);

      switch (group.tier) {
        case RuleGroupTier.anchor:
          anchorMatched = true;
          anchorInSubject |= groupInSubject;
          if (spec.id == RuleGroupId.offer) offerAnchorMatched = true;
        case RuleGroupTier.support:
          supportMatched = true;
        case RuleGroupTier.informational:
          recruiterMatched = true;
        case RuleGroupTier.demote:
          digestMatched = true;
        case RuleGroupTier.weak:
          break;
      }

      final category = spec.category;
      if (category != null) matchedCategories.add(category);
    }

    // Video and AI interview platforms are decisive on the sender alone:
    // receiving mail from one means an interview task has been assigned,
    // whatever the wording.
    for (final domain in rules.interviewPlatformDomains) {
      final needle = domain.toLowerCase().trim();
      if (needle.isEmpty || !_hostMatches(host, needle)) continue;
      score += RuleSet.interviewPlatformWeight;
      anchorMatched = true;
      decisiveSender = true;
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
      final compiled = _Phrase(phrase, normalizedPhrase);
      if (_matches(compiled, normalizedSubject) ||
          _matches(compiled, normalizedBody)) {
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

    // "Interview with Acme" is how half of all real invitations are worded, and
    // also how a podcast newsletter is worded. Scheduling wording plus job
    // wording is what separates the two.
    final promotedInterview =
        matchedGroups.contains(RuleGroupId.interviewWord) &&
        rules.tierOf(RuleGroupId.interviewWord) == RuleGroupTier.support &&
        matchedGroups.contains(RuleGroupId.context) &&
        (matchedGroups.contains(RuleGroupId.scheduling) ||
            matchedGroups.contains(RuleGroupId.personal));

    final decisive = anchorMatched || promotedInterview;

    // Digests quote whole job descriptions, so decisive wording turns up in
    // their bodies. Only a decisive phrase in the subject line survives — or a
    // decisive sender, which no digest can fake.
    final blockedByDigest =
        digestMatched && !anchorInSubject && !decisiveSender;

    matchedCategories.sort(
      (MailCategory a, MailCategory b) => b.priority.compareTo(a.priority),
    );
    final category = matchedCategories.isEmpty
        ? MailCategory.other
        : matchedCategories.first;

    if (decisive) {
      reasons.add(
        anchorMatched
            ? 'Decisive wording found (an anchor phrase matched).'
            : 'Decisive by promotion: ambiguous interview wording plus '
                  'scheduling and job wording.',
      );
    } else if (recruiterMatched) {
      reasons.add(
        'Recruiter wording only — nothing is being asked of you, so this is '
        'filed under "Recruiter" and cannot notify.',
      );
    } else if (supportMatched) {
      reasons.add(
        'Only ambiguous wording matched, so this is listed for review rather '
        'than notified.',
      );
    } else {
      reasons.add('No decisive or ambiguous wording matched.');
    }

    if (decisive && blockedByDigest) {
      reasons.add(
        'Job-alert or marketing wording matched and the decisive phrase was '
        'not in the subject line, so the notification is blocked.',
      );
    }

    final MailVerdict verdict;
    if (decisive && !blockedByDigest) {
      if (score >= rules.notifyThreshold) {
        verdict = MailVerdict.notify;
        reasons.add(
          'Score $score >= notify threshold ${rules.notifyThreshold} → notify',
        );
      } else if (score >= rules.reviewThreshold) {
        verdict = MailVerdict.review;
        reasons.add(
          'Score $score >= review threshold ${rules.reviewThreshold} but short '
          'of the notify bar → needs review',
        );
      } else {
        verdict = MailVerdict.ignore;
        reasons.add(
          'Score $score < review threshold ${rules.reviewThreshold} → ignored',
        );
      }
    } else if (recruiterMatched) {
      verdict = MailVerdict.informational;
      reasons.add('Filed under "Recruiter". Listed, never notified.');
    } else if (blockedByDigest) {
      // A digest about jobs is worth listing; a marketing mail that happens to
      // say "would like to offer" is not worth even a review.
      verdict = matchedGroups.contains(RuleGroupId.context)
          ? MailVerdict.informational
          : MailVerdict.ignore;
      reasons.add(
        verdict == MailVerdict.informational
            ? 'Filed under "Recruiter" as a job digest. Listed, never '
                  'notified.'
            : 'Marketing wording with no job wording → ignored.',
      );
    } else if (supportMatched && score >= rules.reviewThreshold) {
      verdict = MailVerdict.review;
      reasons.add(
        'Score $score >= review threshold ${rules.reviewThreshold} → needs '
        'review',
      );
    } else {
      verdict = MailVerdict.ignore;
      reasons.add(
        'Nothing decisive and score $score below the review bar → ignored',
      );
    }

    return Classification(
      category: verdict == MailVerdict.informational
          ? MailCategory.recruiter
          : category,
      score: score,
      reasons: reasons,
      verdict: verdict,
    );
  }
}
