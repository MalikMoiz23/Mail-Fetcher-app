import 'mail_item.dart';

/// How much authority a group of phrases carries.
///
/// This tiering is what makes the engine precise. Before it existed, score
/// simply accumulated, so five weak signals ("your application", a greenhouse.io
/// sender, the word "position") could flag an automated acknowledgement that
/// contained no interview and no offer. Now only decisive wording can raise a
/// notification.
enum RuleGroupTier {
  /// Decisive. One match is enough to notify, given the score threshold.
  anchor('Can notify', 'One match is enough to raise a notification.'),

  /// Suggestive but ambiguous — a scheduling link, "your availability". Lists
  /// the mail under "Needs review". Two of these plus job context can notify.
  support(
    'Review only',
    'Lists the mail under "Needs review" without notifying. Two separate '
        'matches plus job wording can still notify.',
  ),

  /// Contributes score and nothing else. Never lists or notifies on its own.
  weak('Score only', 'Adds confidence to other matches. Never flags alone.');

  const RuleGroupTier(this.label, this.description);

  final String label;
  final String description;

  static RuleGroupTier byName(String name, RuleGroupTier fallback) =>
      RuleGroupTier.values.firstWhere(
        (tier) => tier.name == name,
        orElse: () => fallback,
      );
}

/// Describes one weighted group of phrases in the rule engine.
class RuleGroupSpec {
  const RuleGroupSpec({
    required this.id,
    required this.label,
    required this.weight,
    required this.category,
    required this.defaultTier,
    required this.hint,
  });

  final String id;
  final String label;
  final int weight;

  /// Category this group claims when it matches. `null` means the group only
  /// contributes score without asserting what the mail is about.
  final MailCategory? category;

  final RuleGroupTier defaultTier;
  final String hint;
}

/// The scoring groups, strongest first.
const List<RuleGroupSpec> kRuleGroups = <RuleGroupSpec>[
  RuleGroupSpec(
    id: 'offer',
    label: 'Offer',
    weight: 10,
    category: MailCategory.offer,
    defaultTier: RuleGroupTier.anchor,
    hint: 'Explicit offer wording. Also overrides rejection phrases, because '
        'offer mails routinely recap the process.',
  ),
  RuleGroupSpec(
    id: 'interview',
    label: 'Interview',
    weight: 10,
    category: MailCategory.interview,
    defaultTier: RuleGroupTier.anchor,
    hint: 'Unambiguous interview events: invitations, confirmations, '
        'reschedules, named rounds, AI and video interviews.',
  ),
  RuleGroupSpec(
    id: 'assessment',
    label: 'Assessment',
    weight: 10,
    category: MailCategory.assessment,
    defaultTier: RuleGroupTier.anchor,
    hint: 'Coding tests and take-home assignments, which carry deadlines. '
        'Named platforms are included.',
  ),
  RuleGroupSpec(
    id: 'scheduling',
    label: 'Scheduling and ambiguous wording',
    weight: 4,
    category: null,
    defaultTier: RuleGroupTier.support,
    hint: 'Real invites are sometimes worded this vaguely, and so is a dentist '
        'appointment. Listed for review rather than notified.',
  ),
  RuleGroupSpec(
    id: 'recruiter',
    label: 'Recruiter and acknowledgements',
    weight: 3,
    category: MailCategory.recruiter,
    defaultTier: RuleGroupTier.weak,
    hint: 'Cold outreach and automated "we received your application" mail. '
        'Highest volume, no deadline, so it scores but never flags.',
  ),
  RuleGroupSpec(
    id: 'context',
    label: 'Job context',
    weight: 1,
    category: null,
    defaultTier: RuleGroupTier.weak,
    hint: 'Weak hints that the mail is about employment at all. Required '
        'before two ambiguous scheduling signals may notify.',
  ),
];

/// Everything the classifier is allowed to know, all of it user-editable.
class RuleSet {
  const RuleSet({
    required this.groups,
    required this.tiers,
    required this.rejectionPhrases,
    required this.interviewPlatformDomains,
    required this.senderDomains,
    required this.mutedSenders,
    required this.notifyThreshold,
    required this.reviewThreshold,
  });

  factory RuleSet.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? raw, List<String> fallback) {
      if (raw is! List) return fallback;
      return raw.whereType<String>().toList(growable: false);
    }

    int positive(Object? raw, int fallback) =>
        raw is int && raw > 0 ? raw : fallback;

    final rawGroups = json['groups'];
    final rawTiers = json['tiers'];
    final groups = <String, List<String>>{};
    final tiers = <String, RuleGroupTier>{};
    for (final spec in kRuleGroups) {
      groups[spec.id] = rawGroups is Map
          ? strings(rawGroups[spec.id], defaults.groups[spec.id]!)
          : defaults.groups[spec.id]!;
      final rawTier = rawTiers is Map ? rawTiers[spec.id] : null;
      tiers[spec.id] = rawTier is String
          ? RuleGroupTier.byName(rawTier, spec.defaultTier)
          : spec.defaultTier;
    }

    return RuleSet(
      groups: groups,
      tiers: tiers,
      rejectionPhrases: strings(
        json['rejectionPhrases'],
        defaults.rejectionPhrases,
      ),
      interviewPlatformDomains: strings(
        json['interviewPlatformDomains'],
        defaults.interviewPlatformDomains,
      ),
      senderDomains: strings(json['senderDomains'], defaults.senderDomains),
      mutedSenders: strings(json['mutedSenders'], defaults.mutedSenders),
      notifyThreshold: positive(
        json['notifyThreshold'],
        defaults.notifyThreshold,
      ),
      reviewThreshold: positive(
        json['reviewThreshold'],
        defaults.reviewThreshold,
      ),
    );
  }

  /// Phrase lists keyed by [RuleGroupSpec.id].
  final Map<String, List<String>> groups;

  /// Effective tier per group, allowing the user to promote or demote a whole
  /// group without editing every phrase in it.
  final Map<String, RuleGroupTier> tiers;

  /// Phrases that veto a flag unless an anchor-tier `offer` phrase also matched.
  /// All of these are multi-word on purpose: single words like "unfortunately"
  /// appear in reschedule mails too and would suppress real interviews.
  final List<String> rejectionPhrases;

  /// Video and AI interview platforms. Mail from these hosts is an interview
  /// task by definition, so a match here counts as an anchor.
  ///
  /// Matched on the sender's host rather than on body text because the product
  /// names are not safe as phrases — "willo" is inside "willow", "karat" is
  /// inside "karate".
  final List<String> interviewPlatformDomains;

  /// Applicant tracking systems and job boards. Confirms the mail is about
  /// employment, but says nothing about urgency, so it only scores.
  final List<String> senderDomains;

  /// Substrings of sender addresses that are forced to "ignore" regardless of
  /// score. The escape hatch for job-alert digests.
  final List<String> mutedSenders;

  /// Score needed to notify, on top of the anchor requirement.
  final int notifyThreshold;

  /// Score needed to appear under "Needs review".
  final int reviewThreshold;

  static const int interviewPlatformWeight = 10;
  static const int senderDomainWeight = 3;

  /// Weight multiplier applied to matches found in the subject line.
  static const int subjectMultiplier = 2;

  /// Distinct support-tier matches that, together with job context, are treated
  /// as equivalent to one anchor. One vague signal is noise; two independent
  /// ones plus job wording is a pattern.
  static const int supportMatchesForNotify = 2;

  RuleGroupTier tierOf(String groupId) =>
      tiers[groupId] ??
      kRuleGroups
          .firstWhere(
            (RuleGroupSpec spec) => spec.id == groupId,
            orElse: () => kRuleGroups.last,
          )
          .defaultTier;

  static const RuleSet defaults = RuleSet(
    notifyThreshold: 10,
    reviewThreshold: 4,
    tiers: <String, RuleGroupTier>{
      'offer': RuleGroupTier.anchor,
      'interview': RuleGroupTier.anchor,
      'assessment': RuleGroupTier.anchor,
      'scheduling': RuleGroupTier.support,
      'recruiter': RuleGroupTier.weak,
      'context': RuleGroupTier.weak,
    },
    groups: <String, List<String>>{
      // Explicit offer language only. Generic constructions such as "would
      // like to offer" live in the scheduling group instead, because marketing
      // mail uses them for discounts.
      'offer': <String>[
        'offer letter',
        'letter of offer',
        'job offer',
        'offer of employment',
        'employment offer',
        'formal offer',
        'verbal offer',
        'written offer',
        'offer details',
        'excited to offer',
        'excited to extend',
        'pleased to offer',
        'pleased to extend',
        'happy to offer',
        'delighted to offer',
        'thrilled to offer',
        'extend an offer',
        'extending an offer',
        'extended an offer',
        'accept our offer',
        'accept the offer',
        'appointment letter',
        'letter of appointment',
        'letter of intent',
        'you have been selected for the position',
        'congratulations you have been selected',
        'welcome aboard',
        'welcome to the team',
        'your joining date',
        'date of joining',
        'onboarding details',
        'employee onboarding',
        'pre onboarding',
        'background verification',
      ],
      // Decisive interview events. Bare "interview" is deliberately absent:
      // it appears in newsletters, podcasts and rejection mail. Constructions
      // that name an actual event are listed instead.
      'interview': <String>[
        'interview invitation',
        'invitation to interview',
        'invitation for interview',
        'invite you to interview',
        'invite you for an interview',
        'invited to interview',
        'invited for an interview',
        'interview invite',
        'interview request',
        'request for an interview',
        'interview scheduled',
        'interview is scheduled',
        'interview has been scheduled',
        'schedule an interview',
        'schedule your interview',
        'scheduling your interview',
        'scheduling an interview',
        'book your interview',
        'confirm your interview',
        'interview confirmation',
        'interview confirmed',
        'interview details',
        'interview reminder',
        'upcoming interview',
        'your interview with',
        'your interview for',
        'interview rescheduled',
        'reschedule your interview',
        'interview link',
        'join your interview',
        'phone interview',
        'video interview',
        'onsite interview',
        'on site interview',
        'in person interview',
        'technical interview',
        'final interview',
        'first round interview',
        'second round interview',
        'panel interview',
        'ai interview',
        'ai powered interview',
        'ai based interview',
        'automated interview',
        'asynchronous interview',
        'one way interview',
        'recorded interview',
        'video screening',
        'phone screen',
        'screening call',
        'screening interview',
        'technical round',
        'hr round',
        'final round',
        'you have been shortlisted',
        'shortlisted for',
        'selected for interview',
        'selected for the interview',
        'proceed to the next round',
        'next round of interviews',
        'moving forward with your application',
        'move forward with your application',
        'proceed to the next stage',
        'next stage of the process',
        // Platform names distinctive enough to be safe as body phrases.
        'hirevue',
        'vidcruiter',
        'hireflix',
        'jobma',
        'sparkhire',
        'spark hire',
        'myinterview',
        'modernhire',
        'micro1',
        'talently ai',
      ],
      // Bare "assessment" is absent on purpose: "risk assessment" and "self
      // assessment" are common in unrelated mail.
      'assessment': <String>[
        'coding challenge',
        'coding test',
        'coding assessment',
        'coding assignment',
        'coding exercise',
        'technical assessment',
        'technical test',
        'online assessment',
        'online test',
        'aptitude test',
        'skills assessment',
        'take home assignment',
        'take home test',
        'take home challenge',
        'assessment link',
        'assessment invitation',
        'complete the assessment',
        'complete your assessment',
        'complete the assignment',
        'submit the assignment',
        'test link',
        'hackerrank',
        'hackerearth',
        'codility',
        'codesignal',
        'testgorilla',
        'testdome',
        'devskiller',
        'coderpad',
      ],
      'scheduling': <String>[
        'interview with',
        'interview for',
        'interview at',
        'your availability',
        'availability for a call',
        'available for a call',
        'share your availability',
        'let me know your availability',
        'schedule a call',
        'schedule a meeting',
        'set up a call',
        'set up a time',
        'book a slot',
        'book a time',
        'pick a time',
        'find a time',
        'next steps',
        'invite you to',
        'meet the team',
        'speak with you',
        'chat with you',
        'quick call',
        'would like to offer',
        'want to offer you',
        'glad to offer',
        'assessment',
        'compensation package',
        'salary package',
        'ctc',
        'calendly.com',
        'meet.google.com',
        'zoom.us',
        'teams.microsoft.com',
      ],
      'recruiter': <String>[
        'job opportunity',
        'career opportunity',
        'exciting opportunity',
        'we are hiring',
        'talent acquisition',
        'hiring manager',
        'recruiter',
        'your application',
        'application received',
        'received your application',
        'application status',
        'thank you for applying',
        'thanks for applying',
        'your resume',
        'your cv',
        'your profile',
        'job description',
        'open position',
        'position at',
        'role at',
        'vacancy',
        'requisition',
      ],
      'context': <String>[
        'hiring',
        'recruitment',
        'candidate',
        'applicant',
        'resume',
        'employment',
        'salary',
        'position',
        'career',
        'job',
        'role',
      ],
    },
    rejectionPhrases: <String>[
      'we regret to inform',
      'regret to inform you',
      'not moving forward',
      'not be moving forward',
      'decided not to move forward',
      'decided not to proceed',
      'will not be proceeding',
      'not proceeding with your application',
      'other candidates',
      'another candidate',
      'move forward with another candidate',
      'better suited candidates',
      'was not selected',
      'were not selected',
      'not been selected',
      'not shortlisted',
      'application has been rejected',
      'unsuccessful on this occasion',
      'not successful on this occasion',
      'position has been filled',
      'role has been filled',
      'we have filled the position',
      'keep your resume on file',
      'keep your cv on file',
      'keep your details on file',
      'keep your application on file',
      'no longer being considered',
      'no longer under consideration',
      'not a fit at this time',
      'not the right fit',
      'pursue other candidates',
      'wish you the best in your job search',
      'best of luck in your search',
    ],
    interviewPlatformDomains: <String>[
      'hirevue.com',
      'willo.video',
      'micro1.ai',
      'talently.ai',
      'sparkhire.com',
      'myinterview.com',
      'vidcruiter.com',
      'modernhire.com',
      'karat.io',
      'hireflix.com',
      'jobma.com',
      'apriora.ai',
      'mercor.com',
      'interviewer.ai',
      'metaview.ai',
      'goodtime.io',
    ],
    senderDomains: <String>[
      'greenhouse.io',
      'lever.co',
      'ashbyhq.com',
      'workable.com',
      'smartrecruiters.com',
      'myworkday.com',
      'myworkdayjobs.com',
      'icims.com',
      'taleo.net',
      'bamboohr.com',
      'breezy.hr',
      'jobvite.com',
      'recruitee.com',
      'teamtailor.com',
      'jazzhr.com',
      'linkedin.com',
      'indeed.com',
      'glassdoor.com',
      'naukri.com',
      'rozee.pk',
      'bayt.com',
      'wellfound.com',
      'hired.com',
    ],
    mutedSenders: <String>[],
  );

  RuleSet copyWith({
    Map<String, List<String>>? groups,
    Map<String, RuleGroupTier>? tiers,
    List<String>? rejectionPhrases,
    List<String>? interviewPlatformDomains,
    List<String>? senderDomains,
    List<String>? mutedSenders,
    int? notifyThreshold,
    int? reviewThreshold,
  }) => RuleSet(
    groups: groups ?? this.groups,
    tiers: tiers ?? this.tiers,
    rejectionPhrases: rejectionPhrases ?? this.rejectionPhrases,
    interviewPlatformDomains:
        interviewPlatformDomains ?? this.interviewPlatformDomains,
    senderDomains: senderDomains ?? this.senderDomains,
    mutedSenders: mutedSenders ?? this.mutedSenders,
    notifyThreshold: notifyThreshold ?? this.notifyThreshold,
    reviewThreshold: reviewThreshold ?? this.reviewThreshold,
  );

  /// Returns a copy with [phrases] replacing the list of the group [groupId].
  RuleSet withGroup(String groupId, List<String> phrases) =>
      copyWith(groups: <String, List<String>>{...groups, groupId: phrases});

  /// Returns a copy with [tier] replacing the tier of the group [groupId].
  RuleSet withTier(String groupId, RuleGroupTier tier) =>
      copyWith(tiers: <String, RuleGroupTier>{...tiers, groupId: tier});

  Map<String, Object?> toJson() => <String, Object?>{
    'groups': groups,
    'tiers': tiers.map(
      (String id, RuleGroupTier tier) => MapEntry<String, String>(
        id,
        tier.name,
      ),
    ),
    'rejectionPhrases': rejectionPhrases,
    'interviewPlatformDomains': interviewPlatformDomains,
    'senderDomains': senderDomains,
    'mutedSenders': mutedSenders,
    'notifyThreshold': notifyThreshold,
    'reviewThreshold': reviewThreshold,
  };
}
