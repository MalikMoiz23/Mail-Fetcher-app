import 'mail_item.dart';

/// How much authority a group of phrases carries.
///
/// This tiering is what makes the engine precise. A plain sum lets weak signals
/// conspire: "your application" plus a greenhouse.io sender plus the word
/// "position" once added up to a notification about an automated
/// acknowledgement containing no interview and no offer.
enum RuleGroupTier {
  /// Decisive. One match is enough to notify, given the score threshold.
  anchor('Can notify', 'One match is enough to raise a notification.'),

  /// Suggestive but ambiguous — a scheduling link, "your availability". Lists
  /// the mail under "Needs review" and never notifies on its own.
  support(
    'Review only',
    'Lists the mail under "Needs review" without ever notifying.',
  ),

  /// Proves the mail is about employment but asks nothing of the reader: cold
  /// outreach, application acknowledgements. Files the mail under "Recruiter".
  informational(
    'Recruiter list only',
    'Files the mail under "Recruiter". It can never notify, whatever else '
        'matches alongside it.',
  ),

  /// Marketing and job-alert digests. Blocks a notification outright unless
  /// decisive wording appears in the subject line.
  demote(
    'Blocks notifications',
    'Job alerts, digests and marketing. Blocks a notification unless decisive '
        'wording appears in the subject line itself.',
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

/// Stable ids of the shipped groups. The classifier needs to name a few of them
/// directly, and a typo in a string literal there would fail silently.
class RuleGroupId {
  const RuleGroupId._();

  static const String offer = 'offer';
  static const String interview = 'interview';
  static const String assessment = 'assessment';
  static const String interviewWord = 'interviewWord';
  static const String scheduling = 'scheduling';
  static const String personal = 'personal';
  static const String recruiter = 'recruiter';
  static const String context = 'context';
  static const String digest = 'digest';
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
    id: RuleGroupId.offer,
    label: 'Offer letter',
    weight: 10,
    category: MailCategory.offer,
    defaultTier: RuleGroupTier.anchor,
    hint:
        'Explicit offer and onboarding wording. Also overrides rejection '
        'phrases, because offer mails routinely recap the process.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.interview,
    label: 'Interview invitation',
    weight: 10,
    category: MailCategory.interview,
    defaultTier: RuleGroupTier.anchor,
    hint:
        'Wording that can only describe an actual interview event: '
        'invitations, confirmations, reschedules, named rounds, AI and video '
        'interviews.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.assessment,
    label: 'Assessment or test',
    weight: 10,
    category: MailCategory.assessment,
    defaultTier: RuleGroupTier.anchor,
    hint:
        'Coding tests and take-home assignments, which carry deadlines. Named '
        'platforms are included.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.interviewWord,
    label: 'Ambiguous interview wording',
    weight: 4,
    category: MailCategory.interview,
    defaultTier: RuleGroupTier.support,
    hint:
        'The word "interview" without an event around it. A podcast '
        'newsletter says "interview with the CEO"; so does a real invitation '
        'titled "Interview with Acme". On its own this only earns a review — '
        'it is promoted to a notification when scheduling wording and job '
        'wording appear alongside it.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.scheduling,
    label: 'Scheduling wording',
    weight: 4,
    category: null,
    defaultTier: RuleGroupTier.support,
    hint:
        'Real invites are sometimes worded this vaguely, and so is a dentist '
        'appointment. Listed for review rather than notified.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.recruiter,
    label: 'Recruiter outreach',
    weight: 3,
    category: MailCategory.recruiter,
    defaultTier: RuleGroupTier.informational,
    hint:
        'Cold outreach, "job opportunity" mail and automated "we received '
        'your application" acknowledgements. Highest volume, nothing to do '
        'about it, so it is filed under "Recruiter" and can never notify.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.personal,
    label: 'Addressed to you as a candidate',
    weight: 2,
    category: null,
    defaultTier: RuleGroupTier.weak,
    hint:
        'Second-person wording that proves the mail concerns the reader\'s own '
        'application rather than reporting on hiring in general.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.context,
    label: 'Job context',
    weight: 1,
    category: null,
    defaultTier: RuleGroupTier.weak,
    hint:
        'Weak hints that the mail is about employment at all. Required before '
        'ambiguous interview wording may be promoted.',
  ),
  RuleGroupSpec(
    id: RuleGroupId.digest,
    label: 'Job alerts and marketing',
    weight: 0,
    category: MailCategory.recruiter,
    defaultTier: RuleGroupTier.demote,
    hint:
        'Job-board digests, "apply now" blasts and promotional mail. These '
        'quote job descriptions verbatim, so decisive wording turns up in '
        'their bodies. A match blocks the notification unless the decisive '
        'wording is in the subject line.',
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
  /// task by definition, so a match here counts as decisive.
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

  /// Score needed to notify, on top of the decisive-wording requirement.
  final int notifyThreshold;

  /// Score needed to appear under "Needs review".
  final int reviewThreshold;

  static const int interviewPlatformWeight = 10;
  static const int senderDomainWeight = 3;

  /// Weight multiplier applied to matches found in the subject line. Senders
  /// put the point of the mail in the subject; bodies carry boilerplate,
  /// quoted history and, in a digest, other people's job descriptions.
  static const int subjectMultiplier = 2;

  RuleGroupTier tierOf(String groupId) =>
      tiers[groupId] ??
      kRuleGroups
          .firstWhere(
            (RuleGroupSpec spec) => spec.id == groupId,
            orElse: () => kRuleGroups.last,
          )
          .defaultTier;

  List<String> phrasesOf(String groupId) =>
      groups[groupId] ?? const <String>[];

  static const RuleSet defaults = RuleSet(
    notifyThreshold: 10,
    reviewThreshold: 4,
    tiers: <String, RuleGroupTier>{
      RuleGroupId.offer: RuleGroupTier.anchor,
      RuleGroupId.interview: RuleGroupTier.anchor,
      RuleGroupId.assessment: RuleGroupTier.anchor,
      RuleGroupId.interviewWord: RuleGroupTier.support,
      RuleGroupId.scheduling: RuleGroupTier.support,
      RuleGroupId.recruiter: RuleGroupTier.informational,
      RuleGroupId.personal: RuleGroupTier.weak,
      RuleGroupId.context: RuleGroupTier.weak,
      RuleGroupId.digest: RuleGroupTier.demote,
    },
    groups: <String, List<String>>{
      // Explicit offer language only. Generic constructions such as "would
      // like to offer" live in the scheduling group instead, because marketing
      // mail uses them for discounts.
      RuleGroupId.offer: <String>[
        'offer letter',
        'letter of offer',
        'job offer',
        'offer of employment',
        'offer of appointment',
        'employment offer',
        'formal offer',
        'verbal offer',
        'written offer',
        'offer details',
        'offer is attached',
        'attached offer',
        'signed offer',
        'offer acceptance',
        'accept our offer',
        'accept the offer',
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
        'appointment letter',
        'letter of appointment',
        'letter of intent',
        'joining letter',
        'employment contract',
        'contract of employment',
        'employment agreement',
        'confirmation of employment',
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
      // Decisive interview events. Bare "interview" is deliberately absent: it
      // appears in newsletters, podcasts and rejection mail. Constructions
      // that name an actual event are listed instead.
      RuleGroupId.interview: <String>[
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
        'set up an interview',
        'arrange an interview',
        'book your interview',
        'confirm your interview',
        'interview confirmation',
        'interview confirmed',
        'interview details',
        'interview reminder',
        'upcoming interview',
        'attend an interview',
        'attend the interview',
        'available for an interview',
        'interview availability',
        'your interview with',
        'your interview for',
        'your interview is',
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
        'coding interview',
        'system design interview',
        'final interview',
        'first round interview',
        'second round interview',
        'panel interview',
        'hr interview',
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
        'managerial round',
        'final round',
        'culture fit round',
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
      // assessment" are common in unrelated mail. It sits in the scheduling
      // group, which reviews rather than notifies.
      RuleGroupId.assessment: <String>[
        'coding challenge',
        'coding test',
        'coding assessment',
        'coding assignment',
        'coding exercise',
        'coding round',
        'technical assessment',
        'technical test',
        'online assessment',
        'online test',
        'aptitude test',
        'aptitude round',
        'proctored test',
        'psychometric test',
        'skills assessment',
        'take home assignment',
        'take home test',
        'take home challenge',
        'assessment link',
        'assessment invitation',
        'assessment deadline',
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
        'mettl',
        'imocha',
        'doselect',
      ],
      // The word "interview" without an event around it.
      RuleGroupId.interviewWord: <String>[
        'interview with',
        'interview for',
        'interview at',
        'interview on',
        'interview process',
        'interview stage',
        'interview round',
        'interview panel',
        'interview slot',
        'interview time',
        'interviewer',
      ],
      RuleGroupId.scheduling: <String>[
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
        'confirm your attendance',
        'meeting link',
        'join the meeting',
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
      RuleGroupId.recruiter: <String>[
        'job opportunity',
        'career opportunity',
        'exciting opportunity',
        'opportunity at',
        'we are hiring',
        'hiring for',
        'job openings',
        'open roles',
        'open positions',
        'came across your profile',
        'saw your profile',
        'reaching out about',
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
        'refer a friend',
        'referral bonus',
      ],
      RuleGroupId.personal: <String>[
        'your candidacy',
        'your interview',
        'your assessment',
        'your offer',
        'your submission',
        'your onboarding',
        'your joining',
        'your start date',
        'your recruitment',
        'you applied',
        'you had applied',
        'we received your',
        'regarding your application',
        'for the position you applied',
      ],
      RuleGroupId.context: <String>[
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
      // Weight 0: these decide nothing by score, they only block. Phrases are
      // multi-word or distinctive so that "off" never matches on its own.
      RuleGroupId.digest: <String>[
        'job alert',
        'job alerts',
        'jobs for you',
        'jobs you may be interested',
        'recommended jobs',
        'recommended for you',
        'jobs matching',
        'similar jobs',
        'more jobs',
        'top jobs',
        'new jobs',
        'view all jobs',
        'browse jobs',
        'job digest',
        'weekly digest',
        'daily digest',
        'apply now',
        'apply today',
        'unsubscribe from job alerts',
        'newsletter',
        'webinar',
        'free trial',
        'off your first',
        'off your next',
        'limited time',
        'flash sale',
        'sale ends',
        'shop now',
        'order now',
        'promo code',
        'discount code',
        'upgrade your plan',
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
      (String id, RuleGroupTier tier) =>
          MapEntry<String, String>(id, tier.name),
    ),
    'rejectionPhrases': rejectionPhrases,
    'interviewPlatformDomains': interviewPlatformDomains,
    'senderDomains': senderDomains,
    'mutedSenders': mutedSenders,
    'notifyThreshold': notifyThreshold,
    'reviewThreshold': reviewThreshold,
  };
}
