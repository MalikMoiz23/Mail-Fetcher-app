import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/mail_item.dart';
import '../state/app_state.dart';
import 'category_style.dart';
import 'theme.dart';

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

  Future<void> _archive() async {
    await appState.archive(widget.item.uid);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    // The header follows the verdict as the user changes it, so the screen
    // never shows a stale colour next to a fresh decision.
    final style = CategoryStyle.forItem(item.copyWith(verdict: _verdict));
    final accent = style.color(theme.brightness);
    final flagged = _verdict == MailVerdict.notify;

    return Scaffold(
      appBar: AppBar(
        title: Text(item.displayLabel),
        actions: <Widget>[
          IconButton(
            tooltip: 'Archive',
            icon: const Icon(Icons.archive_outlined),
            onPressed: _archive,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: style.container(theme.brightness),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(style.icon, size: 14, color: accent),
                            const SizedBox(width: 6),
                            Text(
                              item.category.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'score ${item.score}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(item.subject, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _MetaRow(
                    icon: Icons.person_outline,
                    text: item.fromName.isEmpty
                        ? item.fromEmail
                        : '${item.fromName} <${item.fromEmail}>',
                  ),
                  const SizedBox(height: 6),
                  _MetaRow(
                    icon: Icons.schedule,
                    text: DateFormat(
                      'EEE d MMM yyyy, HH:mm',
                    ).format(item.date),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _VerdictBanner(verdict: _verdict),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _openInGmail,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open in Gmail'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _setVerdict(
                    flagged ? MailVerdict.ignore : MailVerdict.notify,
                  ),
                  icon: Icon(
                    flagged ? Icons.star : Icons.star_outline,
                    size: 18,
                  ),
                  label: Text(flagged ? 'Not important' : 'Important'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Setting it by hand pins the decision: later rule changes will not '
            'override this message.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Text('Message text', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                item.body.isEmpty
                    ? 'No text was downloaded for this message. Very large '
                          'messages are fetched as headers first and their '
                          'text parts in a second pass; if that pass failed, '
                          'only the subject was scored.'
                    : item.body,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                leading: const Icon(Icons.rule),
                title: Text(
                  'Why this verdict',
                  style: theme.textTheme.titleMedium,
                ),
                subtitle: Text(
                  '${item.reasons.length} '
                  '${item.reasons.length == 1 ? 'rule' : 'rules'} fired · '
                  'total score ${item.score}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                children: <Widget>[
                  if (item.reasons.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No rule matched.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
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
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                reason,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
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
    final (IconData icon, String title, String detail) = switch (verdict) {
      MailVerdict.notify => (
        Icons.notifications_active_outlined,
        'Notified',
        'Decisive interview, offer or assessment wording matched, so a '
            'notification was sent for this message.',
      ),
      MailVerdict.review => (
        Icons.help_outline,
        'Needs review',
        'Suggestive wording only, so it was listed without notifying. Add its '
            'exact wording under Settings → Detection rules to have mail like '
            'it notified in future.',
      ),
      MailVerdict.informational => (
        Icons.person_search_outlined,
        'Recruiter mail',
        'Outreach or an acknowledgement: about employment, but nothing is '
            'being asked of you. Mail in this class can never notify.',
      ),
      MailVerdict.rejected => (
        Icons.do_not_disturb_on_outlined,
        'Read as a rejection',
        'Rejection wording matched and no offer wording overrode it, so it '
            'was suppressed.',
      ),
      MailVerdict.ignore => (
        Icons.visibility_off_outlined,
        'Ignored',
        'Nothing decisive matched, so no notification was sent.',
      ),
    };
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.7,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
