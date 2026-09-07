import 'package:flutter_test/flutter_test.dart';
import 'package:mail_fetching_app/models/mail_item.dart';
import 'package:mail_fetching_app/models/rule_set.dart';
import 'package:mail_fetching_app/services/classifier.dart';

Classification run({
  required String subject,
  String body = '',
  String from = 'someone@example.com',
  RuleSet? rules,
}) => Classifier(rules ?? RuleSet.defaults).classify(
  subject: subject,
  body: body,
  fromEmail: from,
);

void main() {
  group('notifies on decisive interview wording', () {
    test('interview invitation', () {
      final result = run(
        subject: 'Interview invitation - Backend Engineer at Acme',
        body: 'Please share your availability for a call this week.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('interview already scheduled', () {
      final result = run(
        subject: 'Your interview is scheduled for Thursday',
        body: 'Join using the link below.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('AI interview', () {
      final result = run(
        subject: 'Complete your AI interview for the Backend role',
        body: 'You have 48 hours to finish the automated interview.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('one-way video interview', () {
      final result = run(
        subject: 'Next step: one-way interview',
        body: 'Record your answers to five questions.',
      );
      expect(result.verdict, MailVerdict.notify);
    });

    test('shortlisted', () {
      final result = run(
        subject: 'You have been shortlisted for Software Engineer',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('body-only decisive wording still notifies', () {
      // Anchor weight equals the notify threshold precisely so that a decisive
      // phrase buried in the body is enough on its own.
      final result = run(
        subject: 'Acme Corp',
        body: 'We would like to schedule an interview with you next week.',
      );
      expect(result.verdict, MailVerdict.notify);
    });

    test('word-start matching catches inflections', () {
      final result = run(subject: 'Scheduling your interviews');
      expect(result.verdict, MailVerdict.notify);
    });

    test('mail from an AI interview platform notifies on the sender alone', () {
      final result = run(
        subject: 'Your task is ready',
        from: 'no-reply@hirevue.com',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('subdomain of an interview platform also matches', () {
      final result = run(
        subject: 'Your task is ready',
        from: 'no-reply@mail.willo.video',
      );
      expect(result.verdict, MailVerdict.notify);
    });

    test('every interview and assessment phrase clears the notify bar', () {
      // Any anchor phrase that scored below the threshold would be dead
      // weight in the list, so this holds the two lists to their promise.
      for (final group in <String>[
        RuleGroupId.interview,
        RuleGroupId.assessment,
      ]) {
        for (final phrase in RuleSet.defaults.groups[group]!) {
          final result = run(subject: phrase);
          expect(
            result.verdict,
            MailVerdict.notify,
            reason: '$group phrase "$phrase" did not notify',
          );
        }
      }
    });
  });

  group('notifies on decisive offer wording', () {
    test('excited to offer', () {
      final result = run(
        subject: 'Acme Corp',
        body: 'We are excited to offer you the position of Backend Engineer.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('offer letter', () {
      final result = run(subject: 'Offer letter - Acme Corp');
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('pleased to extend', () {
      final result = run(
        subject: 'Great news',
        body: 'We are pleased to extend an offer of employment to you.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('offer outranks the interview wording it also contains', () {
      final result = run(
        subject: 'Offer of employment - Acme',
        body: 'Following your interview with the team we are pleased to offer '
            'you the role.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('congratulations on selection', () {
      final result = run(
        subject: 'Congratulations! You have been selected for the position',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('an appointment letter notifies even with no other signal', () {
      final result = run(
        subject: 'Appointment letter',
        body: 'Please find it attached.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('an offer letter buried in the body of a plain mail notifies', () {
      final result = run(
        subject: 'Acme',
        body: 'Your offer letter is attached. Your joining date is 1 October.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('onboarding paperwork counts as an offer', () {
      final result = run(
        subject: 'Onboarding details for your joining',
        body: 'Background verification starts next week.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('every offer phrase on its own clears the notify bar', () {
      // The user-facing promise is that an offer is never missed, so no single
      // offer phrase may score below the threshold when it lands in a subject.
      for (final phrase in RuleSet.defaults.groups[RuleGroupId.offer]!) {
        final result = run(subject: phrase);
        expect(
          result.verdict,
          MailVerdict.notify,
          reason: 'offer phrase "$phrase" did not notify',
        );
      }
    });
  });

  group('notifies on assessments', () {
    test('named platform', () {
      final result = run(
        subject: 'Your HackerRank coding challenge',
        body: 'Complete the assignment within 72 hours using the test link.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.assessment);
    });

    test('take-home assignment', () {
      final result = run(subject: 'Take-home assignment for the Backend role');
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.assessment);
    });

    test('bare "assessment" is not decisive on its own', () {
      // "risk assessment" and "self assessment" are common in unrelated mail,
      // so the bare word only earns a review.
      final result = run(subject: 'Your annual risk assessment is due');
      expect(result.verdict, isNot(MailVerdict.notify));
    });
  });

  group('recruiter mail is listed but never notified', () {
    test('automated application acknowledgement', () {
      // This is the case the anchor requirement exists for. Under a purely
      // additive score it reached the threshold and notified.
      final result = run(
        subject: 'Your application to Acme',
        body: 'Thank you for applying. We will review your resume for this '
            'position and be in touch.',
        from: 'no-reply@greenhouse.io',
      );
      expect(result.verdict, MailVerdict.informational);
      expect(result.category, MailCategory.recruiter);
      expect(result.shouldNotify, isFalse);
      expect(result.score, greaterThan(RuleSet.defaults.reviewThreshold));
    });

    test('cold outreach about a job opportunity is not an interview call', () {
      final result = run(
        subject: 'Exciting job opportunity at Acme',
        body: 'I am a recruiter and saw your profile. Great salary on offer.',
        from: 'talent@acme.com',
      );
      expect(result.verdict, MailVerdict.informational);
      expect(result.category, MailCategory.recruiter);
    });

    test('outreach cannot buy its way in with scheduling wording', () {
      // The exact failure this tier exists for: three ambiguous signals and a
      // hiring-platform sender used to add up to a notification about a mail
      // containing no interview and no offer.
      final result = run(
        subject: 'Job opportunity at Acme — next steps',
        body: 'We would like to invite you to hear about this open position. '
            'Let me know your availability and pick a time that suits. '
            'Salary is competitive for the role.',
        from: 'talent@lever.co',
      );
      expect(result.verdict, MailVerdict.informational);
      expect(result.shouldNotify, isFalse);
      expect(result.score, greaterThan(RuleSet.defaults.notifyThreshold));
    });

    test('weak signals cannot conspire, however many there are', () {
      final result = run(
        subject: 'Your application status - open position at Acme',
        body: 'Hiring, recruitment, candidate, applicant, resume, employment, '
            'salary, position, career, job, role. Your CV and your profile '
            'were received. Job description attached. Requisition 12345.',
        from: 'jobs@linkedin.com',
      );
      expect(result.verdict, MailVerdict.informational);
      expect(result.shouldNotify, isFalse);
    });

    test('an invitation that also mentions your application still notifies', () {
      // Recruiter wording must not veto decisive wording, only fail to create
      // it: real invitations routinely recap the application.
      final result = run(
        subject: 'Interview invitation — Acme',
        body: 'Following your application for this position, we would like to '
            'schedule an interview.',
        from: 'no-reply@greenhouse.io',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('promoting the recruiter group lets those mails notify again', () {
      final rules = RuleSet.defaults.withTier(
        RuleGroupId.recruiter,
        RuleGroupTier.anchor,
      );
      final result = run(
        subject: 'Your application to Acme',
        body: 'Thank you for applying for this position.',
        from: 'no-reply@greenhouse.io',
        rules: rules,
      );
      expect(result.verdict, MailVerdict.notify);
    });
  });

  group('job alerts and marketing cannot notify', () {
    test('a digest quoting an interview invitation is only listed', () {
      // Job boards paste whole job descriptions into their digests, so
      // decisive wording turns up in the body of mail addressed to nobody.
      final result = run(
        subject: 'Jobs for you: 12 new roles this week',
        body: 'Backend Engineer at Acme. Apply now. The process is a '
            'technical interview followed by an offer of employment.',
        from: 'jobalerts@indeed.com',
      );
      expect(result.verdict, MailVerdict.informational);
      expect(result.shouldNotify, isFalse);
    });

    test('the same wording in the subject line still notifies', () {
      final result = run(
        subject: 'Interview invitation for the Backend Engineer role',
        body: 'Apply now to more jobs like this one.',
        from: 'no-reply@indeed.com',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('an interview platform outranks digest wording in the body', () {
      final result = run(
        subject: 'Your task is ready',
        body: 'Complete it today. Unsubscribe from job alerts here.',
        from: 'no-reply@hirevue.com',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });
  });

  group('needs review rather than notify', () {
    test('a single ambiguous scheduling phrase', () {
      final result = run(
        subject: 'Quick call?',
        body: 'Can you share your availability?',
      );
      expect(result.verdict, MailVerdict.review);
    });

    test('ambiguous "interview with" in a newsletter body', () {
      final result = run(
        subject: 'This week in tech',
        body: 'Read our interview with the CEO of Acme.',
      );
      expect(result.verdict, MailVerdict.review);
    });

    test('ambiguous interview wording plus scheduling and job wording', () {
      // "Interview with Acme" is how half of all real invitations are worded.
      // On its own it only earns a review; a scheduling link and job wording
      // alongside it are what make it decisive.
      final result = run(
        subject: 'Interview with Acme Corp',
        body: 'Grab a slot at https://calendly.com/acme for the Backend '
            'Engineer position.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });

    test('the same wording with no job context does not notify', () {
      // The podcast case. The word "interview" is not evidence of hiring.
      final result = run(
        subject: 'Interview with the CEO of Acme',
        body: 'Grab a slot at https://calendly.com/acme to join the live '
            'recording.',
      );
      expect(result.verdict, MailVerdict.review);
    });

    test('scheduling wording alone does not notify', () {
      // The dentist case. Scheduling language is not evidence of hiring.
      final result = run(
        subject: 'Please confirm your availability',
        body: 'Book a time at https://calendly.com/dr-smith for your check-up.',
      );
      expect(result.verdict, MailVerdict.review);
    });

    test('review items are never notifiable', () {
      final result = run(
        subject: 'Quick call?',
        body: 'Let me know your availability.',
      );
      expect(result.shouldNotify, isFalse);
    });
  });

  group('suppresses rejections', () {
    test('classic rejection', () {
      final result = run(
        subject: 'Update on your application at Acme',
        body: 'We regret to inform you that we are moving forward with other '
            'candidates.',
      );
      expect(result.verdict, MailVerdict.rejected);
      expect(result.category, MailCategory.rejection);
    });

    test('rejection that recaps a decisive interview is still a rejection', () {
      final result = run(
        subject: 'Your interview with Acme',
        body: 'Thank you for the technical interview. Unfortunately you were '
            'not selected for this position.',
      );
      expect(result.verdict, MailVerdict.rejected);
    });

    test('rejection from an AI interview platform is still a rejection', () {
      final result = run(
        subject: 'Update',
        body: 'We have decided not to proceed with your application.',
        from: 'no-reply@hirevue.com',
      );
      expect(result.verdict, MailVerdict.rejected);
    });

    test('offer wording overrides the rejection veto', () {
      final result = run(
        subject: 'Offer letter - Acme',
        body: 'We interviewed other candidates but would like to extend an '
            'offer to you.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.offer);
    });

    test('a reschedule is not read as a rejection', () {
      // The reason rejection phrases are all multi-word: "unfortunately" on its
      // own appears in mail that matters.
      final result = run(
        subject: 'Interview rescheduled',
        body: 'Unfortunately the interviewer is unwell, so please pick a new '
            'slot.',
      );
      expect(result.verdict, MailVerdict.notify);
      expect(result.category, MailCategory.interview);
    });
  });

  group('ignores unrelated mail', () {
    test('scores nothing at all', () {
      final result = run(
        subject: 'Your electricity bill is ready',
        body: 'Your monthly statement is attached.',
      );
      expect(result.score, 0);
      expect(result.verdict, MailVerdict.ignore);
      expect(result.category, MailCategory.other);
    });

    test('a discount "offer" is not a job offer', () {
      final result = run(
        subject: 'Special offer just for you',
        body: 'We would like to offer you 20% off your next purchase.',
      );
      expect(result.verdict, MailVerdict.ignore);
    });

    test('a webinar invitation is not an interview', () {
      final result = run(
        subject: 'We invite you to our product webinar',
        body: 'Join us on Zoom to meet the team behind the product.',
      );
      expect(result.verdict, MailVerdict.ignore);
    });

    test('muted sender wins over decisive wording', () {
      final rules = RuleSet.defaults.copyWith(
        mutedSenders: <String>['jobalerts-noreply@linkedin.com'],
      );
      final result = run(
        subject: 'Interview invitation - Backend Engineer',
        from: 'jobalerts-noreply@linkedin.com',
        rules: rules,
      );
      expect(result.verdict, MailVerdict.ignore);
      expect(result.score, 0);
    });
  });

  group('scoring mechanics', () {
    test('subject matches are worth double a body match', () {
      final inSubject = run(subject: 'interview invitation');
      final inBody = run(subject: 'hello', body: 'interview invitation');
      expect(inSubject.score, inBody.score * RuleSet.subjectMultiplier);
    });

    test('raising the notify threshold demotes to review', () {
      const subject = 'Interview invitation';
      expect(run(subject: subject).verdict, MailVerdict.notify);
      expect(
        run(
          subject: subject,
          rules: RuleSet.defaults.copyWith(notifyThreshold: 99),
        ).verdict,
        MailVerdict.review,
      );
    });

    test('raising both thresholds drops the mail entirely', () {
      final result = run(
        subject: 'Interview invitation',
        rules: RuleSet.defaults.copyWith(
          notifyThreshold: 99,
          reviewThreshold: 99,
        ),
      );
      expect(result.verdict, MailVerdict.ignore);
    });

    test('every verdict explains itself and names the deciding rule', () {
      final result = run(subject: 'Interview invitation');
      expect(result.reasons, isNotEmpty);
      expect(
        result.reasons.any((String r) => r.contains('Decisive wording')),
        isTrue,
      );
      expect(result.reasons.last, contains('notify'));
    });

    test('a demoted group still contributes score', () {
      final rules = RuleSet.defaults.withTier(
        'interview',
        RuleGroupTier.weak,
      );
      final result = run(subject: 'Interview invitation', rules: rules);
      expect(result.score, greaterThan(0));
      // Weak groups can never flag, however high the score.
      expect(result.verdict, MailVerdict.ignore);
    });
  });

  group('normalisation', () {
    test('punctuation and case are ignored', () {
      expect(
        run(subject: 'INTERVIEW -- INVITATION!!!').verdict,
        MailVerdict.notify,
      );
    });

    test('phrases spanning a line break still match', () {
      final result = run(
        subject: 'Acme',
        body: 'We would like to schedule an\ninterview with you.',
      );
      expect(result.verdict, MailVerdict.notify);
    });

    test('hyphenated wording matches the spaced phrase', () {
      expect(run(subject: 'AI-powered interview').verdict, MailVerdict.notify);
      expect(run(subject: 'Take-home test').verdict, MailVerdict.notify);
    });
  });

  group('rules serialisation', () {
    test('round trips including tiers and both thresholds', () {
      final edited = RuleSet.defaults
          .withGroup('offer', <String>['offer letter'])
          .withTier('recruiter', RuleGroupTier.anchor)
          .copyWith(
            notifyThreshold: 14,
            reviewThreshold: 7,
            mutedSenders: <String>['digest@x.com'],
          );
      final restored = RuleSet.fromJson(edited.toJson());
      expect(restored.notifyThreshold, 14);
      expect(restored.reviewThreshold, 7);
      expect(restored.groups['offer'], <String>['offer letter']);
      expect(restored.tierOf('recruiter'), RuleGroupTier.anchor);
      expect(restored.tierOf('interview'), RuleGroupTier.anchor);
      expect(restored.mutedSenders, <String>['digest@x.com']);
      expect(restored.rejectionPhrases, RuleSet.defaults.rejectionPhrases);
      expect(
        restored.interviewPlatformDomains,
        RuleSet.defaults.interviewPlatformDomains,
      );
    });

    test('missing keys fall back to defaults instead of emptying the rules', () {
      final restored = RuleSet.fromJson(<String, Object?>{
        'notifyThreshold': 0,
      });
      expect(restored.notifyThreshold, RuleSet.defaults.notifyThreshold);
      expect(restored.reviewThreshold, RuleSet.defaults.reviewThreshold);
      expect(
        restored.groups['interview'],
        RuleSet.defaults.groups['interview'],
      );
      expect(restored.tierOf('scheduling'), RuleGroupTier.support);
    });

    test('an unknown tier name falls back to the group default', () {
      final restored = RuleSet.fromJson(<String, Object?>{
        'tiers': <String, Object?>{'interview': 'nonsense'},
      });
      expect(restored.tierOf('interview'), RuleGroupTier.anchor);
    });
  });
}
