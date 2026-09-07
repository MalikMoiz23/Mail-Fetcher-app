import 'package:flutter/material.dart';

import '../models/rule_set.dart';
import '../state/app_state.dart';

/// Editor for the scoring rules.
///
/// Every change rescores the cached mail immediately, so the effect of a tweak
/// is visible without waiting for the next poll.
class RulesEditorScreen extends StatelessWidget {
  const RulesEditorScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appState,
    builder: (BuildContext context, Widget? child) {
      final rules = appState.rules;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Detection rules'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Restore defaults',
              icon: const Icon(Icons.restart_alt),
              onPressed: () => _restoreDefaults(context),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: <Widget>[
            const _Explainer(),
            _ThresholdSlider(
              title: 'Notify threshold',
              description:
                  'Score needed to notify, on top of the decisive-wording '
                  'requirement. Raise it to demand more corroboration.',
              value: rules.notifyThreshold,
              min: 4,
              max: 30,
              onCommitted: (int value) async {
                final changed = await appState.updateRules(
                  rules.copyWith(notifyThreshold: value),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
            _ThresholdSlider(
              title: 'Review threshold',
              description:
                  'Score needed to appear under "Needs review". Lower it to '
                  'catch more, at the cost of a longer review pile.',
              value: rules.reviewThreshold,
              min: 1,
              max: 20,
              onCommitted: (int value) async {
                final changed = await appState.updateRules(
                  rules.copyWith(reviewThreshold: value),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
            const Divider(),
            for (final spec in kRuleGroups)
              _GroupTile(
                spec: spec,
                tier: rules.tierOf(spec.id),
                phrases: rules.groups[spec.id] ?? const <String>[],
                onPhrasesChanged: (List<String> phrases) async {
                  final changed = await appState.updateRules(
                    rules.withGroup(spec.id, phrases),
                  );
                  if (!context.mounted) return;
                  _reportRescore(context, changed);
                },
                onTierChanged: (RuleGroupTier tier) async {
                  final changed = await appState.updateRules(
                    rules.withTier(spec.id, tier),
                  );
                  if (!context.mounted) return;
                  _reportRescore(context, changed);
                },
              ),
            _PhraseListTile(
              title: 'Rejection wording  (veto)',
              subtitle:
                  'Any match suppresses the mail, unless an Offer phrase also '
                  'matched. Keep these multi-word: a single word like '
                  '"unfortunately" also appears in reschedule mails and would '
                  'suppress a real interview.',
              phrases: rules.rejectionPhrases,
              hintText: 'we regret to inform',
              onChanged: (List<String> phrases) async {
                final changed = await appState.updateRules(
                  rules.copyWith(rejectionPhrases: phrases),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
            _PhraseListTile(
              title:
                  'Interview platform domains  '
                  '(+${RuleSet.interviewPlatformWeight}, can notify)',
              subtitle:
                  'Matched against the sender\'s domain. Mail from a video or '
                  'AI interview platform is an interview task by definition, so '
                  'a match here counts as decisive on its own. Domains rather '
                  'than words because the product names are unsafe as phrases — '
                  '"willo" is inside "willow", "karat" inside "karate".',
              phrases: rules.interviewPlatformDomains,
              hintText: 'hirevue.com',
              onChanged: (List<String> phrases) async {
                final changed = await appState.updateRules(
                  rules.copyWith(interviewPlatformDomains: phrases),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
            _PhraseListTile(
              title:
                  'Hiring platform domains  '
                  '(+${RuleSet.senderDomainWeight}, score only)',
              subtitle:
                  'Applicant tracking systems and job boards. Confirms the mail '
                  'is about employment but says nothing about urgency, so it '
                  'only adds score.',
              phrases: rules.senderDomains,
              hintText: 'greenhouse.io',
              onChanged: (List<String> phrases) async {
                final changed = await appState.updateRules(
                  rules.copyWith(senderDomains: phrases),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
            _PhraseListTile(
              title: 'Muted senders',
              subtitle:
                  'Any sender address containing one of these is ignored, '
                  'whatever it scores. Use it for job-alert digests such as '
                  'jobalerts-noreply@linkedin.com.',
              phrases: rules.mutedSenders,
              hintText: 'jobalerts-noreply@linkedin.com',
              onChanged: (List<String> phrases) async {
                final changed = await appState.updateRules(
                  rules.copyWith(mutedSenders: phrases),
                );
                if (!context.mounted) return;
                _reportRescore(context, changed);
              },
            ),
          ],
        ),
      );
    },
  );

  static Future<void> _restoreDefaults(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Restore default rules?'),
        content: const Text(
          'All phrase lists, tiers, thresholds and muted senders go back to '
          'the shipped defaults.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final changed = await appState.resetRules();
    if (!context.mounted) return;
    _reportRescore(context, changed);
  }

  static void _reportRescore(BuildContext context, int changed) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changed == 0
              ? 'Saved. No cached message changed verdict.'
              : 'Saved. $changed cached message'
                    '${changed == 1 ? '' : 's'} rescored.',
        ),
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'A message scores points for every phrase that matches. Subject '
            'matches count double, because senders put the point of the mail '
            'in the subject line.',
            style: style,
          ),
          const SizedBox(height: 8),
          Text(
            'Score alone never notifies. A notification needs decisive '
            'wording: one "Can notify" phrase, mail from an interview '
            'platform, or ambiguous interview wording backed by both '
            'scheduling and job wording. Anything weaker is listed under '
            '"Needs review".',
            style: style,
          ),
          const SizedBox(height: 8),
          Text(
            'Three things take a notification away again: rejection wording '
            '(unless offer wording overrides it), job-alert or marketing '
            'wording when the decisive phrase was only in the body, and '
            '"Recruiter list only" wording, which can never notify however '
            'much it scores.',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.spec,
    required this.tier,
    required this.phrases,
    required this.onPhrasesChanged,
    required this.onTierChanged,
  });

  final RuleGroupSpec spec;
  final RuleGroupTier tier;
  final List<String> phrases;
  final ValueChanged<List<String>> onPhrasesChanged;
  final ValueChanged<RuleGroupTier> onTierChanged;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(
      spec.weight == 0
          ? '${spec.label}  (no score, blocks only)'
          : '${spec.label}  (+${spec.weight} each)',
    ),
    subtitle: Text('${phrases.length} phrases · ${tier.label}'),
    childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
    children: <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: Text(spec.hint, style: Theme.of(context).textTheme.bodySmall),
      ),
      const SizedBox(height: 12),
      Row(
        children: <Widget>[
          const Text('Authority'),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<RuleGroupTier>(
              isExpanded: true,
              value: tier,
              onChanged: (RuleGroupTier? value) {
                if (value != null && value != tier) onTierChanged(value);
              },
              items: RuleGroupTier.values
                  .map(
                    (RuleGroupTier value) => DropdownMenuItem<RuleGroupTier>(
                      value: value,
                      child: Text(value.label),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          tier.description,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      const SizedBox(height: 12),
      _PhraseChips(phrases: phrases, onChanged: onPhrasesChanged),
    ],
  );
}

class _ThresholdSlider extends StatefulWidget {
  const _ThresholdSlider({
    required this.title,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommitted,
  });

  final String title;
  final String description;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onCommitted;

  @override
  State<_ThresholdSlider> createState() => _ThresholdSliderState();
}

class _ThresholdSliderState extends State<_ThresholdSlider> {
  late double _value = widget.value.toDouble();

  @override
  void didUpdateWidget(_ThresholdSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value.toDouble();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${widget.title}: ${_value.round()}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          widget.description,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: _value,
          min: widget.min.toDouble(),
          max: widget.max.toDouble(),
          divisions: widget.max - widget.min,
          label: _value.round().toString(),
          onChanged: (double value) => setState(() => _value = value),
          onChangeEnd: (double value) => widget.onCommitted(value.round()),
        ),
      ],
    ),
  );
}

class _PhraseListTile extends StatelessWidget {
  const _PhraseListTile({
    required this.title,
    required this.subtitle,
    required this.phrases,
    required this.onChanged,
    required this.hintText,
  });

  final String title;
  final String subtitle;
  final List<String> phrases;
  final ValueChanged<List<String>> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(title),
    subtitle: Text('${phrases.length} entries'),
    childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
    children: <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ),
      const SizedBox(height: 12),
      _PhraseChips(
        phrases: phrases,
        onChanged: onChanged,
        hintText: hintText,
      ),
    ],
  );
}

class _PhraseChips extends StatelessWidget {
  const _PhraseChips({
    required this.phrases,
    required this.onChanged,
    this.hintText = 'interview invitation',
  });

  final List<String> phrases;
  final ValueChanged<List<String>> onChanged;
  final String hintText;

  Future<void> _add(BuildContext context) async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Add entry'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hintText,
            helperText: 'Case and punctuation are ignored when matching.',
          ),
          onSubmitted: (String value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final trimmed = entered?.trim() ?? '';
    if (trimmed.isEmpty) return;
    if (phrases.any(
      (String phrase) => phrase.toLowerCase() == trimmed.toLowerCase(),
    )) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That entry is already in the list.')),
      );
      return;
    }
    onChanged(<String>[...phrases, trimmed]);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: <Widget>[
      for (final phrase in phrases)
        InputChip(
          label: Text(phrase),
          onDeleted: () => onChanged(
            phrases.where((String entry) => entry != phrase).toList(),
          ),
        ),
      ActionChip(
        avatar: const Icon(Icons.add, size: 18),
        label: const Text('Add'),
        onPressed: () => _add(context),
      ),
    ],
  );
}
