import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/mail_item.dart';
import '../state/app_state.dart';
import 'category_style.dart';

/// One message, plus the audit trail of why it was or was not flagged.
class MailDetailScreen extends StatefulWidget {
  const MailDetailScreen({required this.item, super.key});

  final MailItem item;

  @override
  State<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends State<MailDetailScreen> {
  late MailVerdict _verdict = widget.item.verdict;

  Future<void> _openInGmail() async {
    final link = widget.item.gmailLink;
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This message had no Message-ID header, so it cannot be linked.',
          ),
        ),
      );
      return;
    }
    await AndroidIntent(
      action: 'action_view',
      data: link,
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    ).launch();
  }

  Future<void> _setVerdict(MailVerdict verdict) async {
    await appState.setVerdict(uid: widget.item.uid, verdict: verdict);
    if (!mounted) return;
    setState(() => _verdict = verdict);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final style = CategoryStyle.forItem(item);
    final theme = Theme.of(context);
    final flagged = _verdict == MailVerdict.notify;
    return Scaffold(
      appBar: AppBar(
        title: Text(item.displayLabel),
        backgroundColor: style.color.withValues(alpha: 0.12),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(item.subject, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(Icons.person_outline, size: 18, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.fromName.isEmpty
                      ? item.fromEmail
                      : '${item.fromName} <${item.fromEmail}>',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Icon(Icons.schedule, size: 18, color: theme.hintColor),
              const SizedBox(width: 8),
              Text(
                DateFormat('EEE d MMM yyyy, HH:mm').format(item.date),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _VerdictBanner(verdict: _verdict),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _openInGmail,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open in Gmail'),
              ),
              OutlinedButton.icon(
                onPressed: () => _setVerdict(
                  flagged ? MailVerdict.ignore : MailVerdict.notify,
                ),
                icon: Icon(flagged ? Icons.star : Icons.star_outline, size: 18),
                label: Text(flagged ? 'Not important' : 'Mark important'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Marking it by hand pins the decision: later rule changes will not '
            'override this message.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Text('Message text', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              item.body.isEmpty
                  ? 'No plain-text body was downloaded for this message. Large '
                        'messages are fetched as headers only to save mobile '
                        'data, so only the subject was scored.'
                  : item.body,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 24),
          Text('Why this verdict', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Every rule that fired, in order. Total score ${item.score}.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (item.reasons.isEmpty)
            Text('No rule matched.', style: theme.textTheme.bodyMedium)
          else
            ...item.reasons.map(
              (String reason) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.hintColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(reason, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// States plainly whether the phone buzzed for this mail, because that is the
/// one thing the user cannot infer from the list.
class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.verdict});

  final MailVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text) = switch (verdict) {
      MailVerdict.notify => (
        Icons.notifications_active_outlined,
        'Flagged as important. A notification was sent for this message.',
      ),
      MailVerdict.review => (
        Icons.help_outline,
        'Needs review. Suggestive wording only, so it was listed but no '
            'notification was sent.',
      ),
      MailVerdict.rejected => (
        Icons.do_not_disturb_on_outlined,
        'Read as a rejection, so it was suppressed. No notification was sent.',
      ),
      MailVerdict.ignore => (
        Icons.visibility_off_outlined,
        'Ignored. Nothing decisive matched, so no notification was sent.',
      ),
    };
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
