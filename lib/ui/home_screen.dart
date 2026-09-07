import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/mail_item.dart';
import '../state/app_state.dart';
import 'category_style.dart';
import 'mail_detail_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The triage list: what needs a decision, newest first.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appState.addListener(_onStateChanged);
    // Coming back to the app is the moment the user expects the list to be
    // current, so refresh rather than waiting for the next poll.
    WidgetsBinding.instance.addPostFrameCallback((_) => appState.sync());
  }

  @override
  void dispose() {
    appState.removeListener(_onStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      appState.refreshPermissionState();
    }
  }

  void _onStateChanged() {
    if (!mounted) return;
    final message = appState.consumeFlash();
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    // A tapped notification arrives here as a loaded message, because the
    // background isolate has no navigator of its own.
    final pending = appState.consumePendingOpen();
    if (pending != null) _open(pending);
  }

  Future<void> _open(MailItem item) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => MailDetailScreen(item: item),
    ),
  );

  void _stopSearching() {
    _search.clear();
    appState.setQuery('');
    setState(() => _searching = false);
  }

  Future<void> _archive(MailItem item) async {
    await appState.archive(item.uid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Archived "${_shorten(item.subject)}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => appState.unarchive(item.uid),
        ),
      ),
    );
  }

  static String _shorten(String text) =>
      text.length <= 40 ? text : '${text.substring(0, 40)}…';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appState,
    builder: (BuildContext context, Widget? child) {
      final rows = _Section.build(appState.items);
      return Scaffold(
        appBar: AppBar(
          titleSpacing: _searching ? 8 : null,
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: appState.setQuery,
                  decoration: InputDecoration(
                    hintText: 'Search subject, sender or text',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: _stopSearching,
                    ),
                  ),
                )
              : const _Title(),
          actions: _searching
              ? const <Widget>[]
              : <Widget>[
                  IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.search),
                    onPressed: () => setState(() => _searching = true),
                  ),
                  IconButton(
                    tooltip: 'Sync now',
                    icon: appState.syncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    onPressed: appState.syncing ? null : appState.sync,
                  ),
                  _OverflowMenu(showEverything: appState.showEverything),
                ],
          // These take their state as constructor arguments rather than
          // reading appState directly: a `const` child is skipped entirely on
          // rebuild (Element.updateChild short-circuits on an identical
          // widget), so a const filter bar would never redraw its selected
          // chip.
          bottom: _FilterBar(
            filter: appState.filter,
            counts: <InboxFilter, int?>{
              for (final value in InboxFilter.values)
                value: appState.countFor(value),
            },
          ),
        ),
        body: RefreshIndicator(
          onRefresh: appState.sync,
          child: CustomScrollView(
            slivers: <Widget>[
              if (appState.lastError != null)
                SliverToBoxAdapter(
                  child: _ErrorBanner(message: appState.lastError!),
                ),
              SliverToBoxAdapter(
                child: _StatusLine(
                  lastSync: appState.lastSync,
                  syncing: appState.syncing,
                  filter: appState.filter,
                  showEverything: appState.showEverything,
                  matches: appState.items.length,
                  query: appState.query,
                ),
              ),
              if (rows.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(
                    filter: appState.filter,
                    query: appState.query,
                    showEverything: appState.showEverything,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (BuildContext context, int index) {
                    final row = rows[index];
                    final item = row.item;
                    if (item == null) {
                      return _SectionHeader(label: row.label!);
                    }
                    return _MailCard(
                      item: item,
                      showScore: appState.showEverything,
                      onTap: () => _open(item),
                      onArchive: () => _archive(item),
                      onToggleFlag: () => appState.setVerdict(
                        uid: item.uid,
                        verdict: item.verdict == MailVerdict.notify
                            ? MailVerdict.ignore
                            : MailVerdict.notify,
                      ),
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      );
    },
  );
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    final email = appState.email;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Text('Important Mail'),
        if (email != null)
          Text(
            email,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.showEverything});

  final bool showEverything;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'More',
    onSelected: (String value) async {
      switch (value) {
        case 'everything':
          await appState.setShowEverything(!showEverything);
        case 'rescan':
          await appState.rescanInbox();
        case 'settings':
          if (!context.mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const SettingsScreen(),
            ),
          );
      }
    },
    itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
      CheckedPopupMenuItem<String>(
        value: 'everything',
        checked: showEverything,
        child: const Text('Show everything'),
      ),
      const PopupMenuItem<String>(
        value: 'rescan',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.restart_alt),
          title: Text('Re-scan inbox'),
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'settings',
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.settings_outlined),
          title: Text('Settings'),
        ),
      ),
    ],
  );
}

class _FilterBar extends StatelessWidget implements PreferredSizeWidget {
  const _FilterBar({required this.filter, required this.counts});

  final InboxFilter filter;
  final Map<InboxFilter, int?> counts;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      children: <Widget>[
        for (final value in InboxFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _FilterChip(
              filter: value,
              selected: filter == value,
              count: counts[value],
            ),
          ),
      ],
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.selected,
    required this.count,
  });

  final InboxFilter filter;
  final bool selected;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(filter);
    final brightness = Theme.of(context).brightness;
    final accent = style?.color(brightness);
    return FilterChip(
      avatar: style == null
          ? null
          : Icon(style.icon, size: 18, color: accent),
      label: Text(
        // The count is the number worth surfacing on the piles that grow
        // silently, because nothing about them is notified.
        count == null || count == 0 ? filter.label : '${filter.label}  $count',
      ),
      selected: selected,
      selectedColor: accent?.withValues(
        alpha: brightness == Brightness.dark ? 0.24 : 0.14,
      ),
      onSelected: (_) => appState.setFilter(filter),
      tooltip: filter.description,
    );
  }

  static CategoryStyle? _styleFor(InboxFilter filter) => switch (filter) {
    InboxFilter.offers => CategoryStyle.of(MailCategory.offer),
    InboxFilter.interviews => CategoryStyle.of(MailCategory.interview),
    InboxFilter.assessments => CategoryStyle.of(MailCategory.assessment),
    InboxFilter.recruiter => CategoryStyle.of(MailCategory.recruiter),
    InboxFilter.needsReview => CategoryStyle.review,
    InboxFilter.all => null,
  };
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.lastSync,
    required this.syncing,
    required this.filter,
    required this.showEverything,
    required this.matches,
    required this.query,
  });

  final DateTime? lastSync;
  final bool syncing;
  final InboxFilter filter;
  final bool showEverything;
  final int matches;
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final parts = <String>[
      if (syncing)
        'Syncing…'
      else if (lastSync == null)
        'Not synced yet'
      else
        'Synced ${_ago(lastSync!)}',
      if (query.isNotEmpty)
        '$matches ${matches == 1 ? 'match' : 'matches'}'
      else
        filter.description,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(parts.join(' · '), style: muted)),
          if (showEverything)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: 'Ignored and rejected mail is included',
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('Everything'),
                  onDeleted: () => appState.setShowEverything(false),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _ago(DateTime when) {
    final gap = DateTime.now().difference(when);
    if (gap.inMinutes < 1) return 'just now';
    if (gap.inMinutes < 60) return '${gap.inMinutes} min ago';
    if (gap.inHours < 24) return '${gap.inHours} h ago';
    return DateFormat.MMMd().add_Hm().format(when);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.cloud_off, size: 20, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Last sync failed. $message',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry in the flattened list: either a date header or a message.
class _Section {
  const _Section.header(this.label) : item = null;

  const _Section.mail(this.item) : label = null;

  final String? label;
  final MailItem? item;

  /// Groups [items] by age. Dates on their own are hard to scan; "Today" and
  /// "Yesterday" are what the reader actually thinks in when a deadline is
  /// involved.
  static List<_Section> build(List<MailItem> items) {
    final rows = <_Section>[];
    String? current;
    for (final item in items) {
      final bucket = _bucket(item.date);
      if (bucket != current) {
        current = bucket;
        rows.add(_Section.header(bucket));
      }
      rows.add(_Section.mail(item));
    }
    return rows;
  }

  static String _bucket(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final gap = today.difference(day).inDays;
    if (gap <= 0) return 'Today';
    if (gap == 1) return 'Yesterday';
    if (gap < 7) return 'Earlier this week';
    if (gap < 30) return 'This month';
    return 'Older';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
    child: Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    ),
  );
}

class _MailCard extends StatelessWidget {
  const _MailCard({
    required this.item,
    required this.showScore,
    required this.onTap,
    required this.onArchive,
    required this.onToggleFlag,
  });

  final MailItem item;
  final bool showScore;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onToggleFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = CategoryStyle.forItem(item);
    final accent = style.color(theme.brightness);
    // Only notified mail gets full visual weight. Review, recruiter and
    // ignored rows are deliberately quieter so the list still reads at a
    // glance.
    final emphasised = item.verdict == MailVerdict.notify;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Dismissible(
        key: ValueKey<int>(item.uid),
        background: _SwipeBackground(
          alignment: Alignment.centerLeft,
          color: accent,
          icon: emphasised ? Icons.star_border : Icons.star,
          label: emphasised ? 'Not important' : 'Important',
        ),
        secondaryBackground: _SwipeBackground(
          alignment: Alignment.centerRight,
          color: theme.colorScheme.onSurfaceVariant,
          icon: Icons.archive_outlined,
          label: 'Archive',
        ),
        confirmDismiss: (DismissDirection direction) async {
          if (direction == DismissDirection.startToEnd) {
            // Flagging is a state change, not a removal: keep the row on
            // screen so the new pill is visible straight away.
            onToggleFlag();
            return false;
          }
          return true;
        },
        onDismissed: (_) => onArchive(),
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: style.container(theme.brightness),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(style.icon, color: accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                item.subject,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: emphasised
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: emphasised
                                      ? null
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatDate(item.date),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.displayFrom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            _Pill(
                              label: item.displayLabel,
                              color: accent,
                              background: style.container(theme.brightness),
                            ),
                            if (showScore) ...<Widget>[
                              const SizedBox(width: 8),
                              Text(
                                'score ${item.score}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (item.userOverride) ...<Widget>[
                              const SizedBox(width: 8),
                              Tooltip(
                                message:
                                    'You set this by hand. Rule changes leave '
                                    'it alone.',
                                child: Icon(
                                  Icons.push_pin_outlined,
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final now = DateTime.now();
    final sameDay =
        date.year == now.year && date.month == now.month && date.day == now.day;
    return sameDay
        ? DateFormat.Hm().format(date)
        : DateFormat.MMMd().format(date);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AppTheme.radius),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.filter,
    required this.query,
    required this.showEverything,
  });

  final InboxFilter filter;
  final String query;
  final bool showEverything;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String title, String detail) = _copy();
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (query.isEmpty && filter != InboxFilter.needsReview)
            OutlinedButton.icon(
              onPressed: () => appState.setFilter(InboxFilter.needsReview),
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Check "Needs review"'),
            ),
        ],
      ),
    );
  }

  (IconData, String, String) _copy() {
    if (query.isNotEmpty) {
      return (
        Icons.search_off,
        'Nothing matches "$query"',
        'Search covers the subject, the sender and the message text of every '
            'message still in the cache.',
      );
    }
    return switch (filter) {
      InboxFilter.needsReview => (
        Icons.done_all,
        'Nothing waiting for review',
        'Mail lands here when its wording is suggestive but not decisive. It '
            'is never notified, so this pile is worth a glance now and then.',
      ),
      InboxFilter.recruiter => (
        Icons.person_search_outlined,
        'No recruiter mail',
        'Cold outreach, "job opportunity" mail and application '
            'acknowledgements are filed here. They never notify.',
      ),
      InboxFilter.all when showEverything => (
        Icons.inbox_outlined,
        'No mail cached yet',
        'Pull down to sync. The first sync reads the newest messages in your '
            'inbox; later ones read only what has arrived since.',
      ),
      InboxFilter.all => (
        Icons.inbox_outlined,
        'Nothing needs you',
        'Interviews, offers and assessments appear here and notify you. Pull '
            'down to sync.',
      ),
      _ => (
        Icons.filter_list_off,
        'No ${filter.label.toLowerCase()} yet',
        'When one arrives it is notified immediately and listed here.',
      ),
    };
  }
}
