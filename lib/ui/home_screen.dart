import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/mail_item.dart';
import '../state/app_state.dart';
import 'category_style.dart';
import 'mail_detail_screen.dart';
import 'settings_screen.dart';

/// The flagged-mail list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      appState.refreshPermissionState();
    }
  }

  void _onStateChanged() {
    final message = appState.consumeFlash();
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appState,
    builder: (BuildContext context, Widget? child) {
      final items = appState.items;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Important Mail'),
          actions: <Widget>[
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
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const SettingsScreen(),
                ),
              ),
            ),
          ],
          // These take their state as constructor arguments rather than reading
          // appState directly: a `const` child is skipped entirely on rebuild
          // (Element.updateChild short-circuits on an identical widget), so a
          // const filter bar would never redraw its selected chip.
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: _FilterBar(
              filter: appState.filter,
              showEverything: appState.showEverything,
              reviewCount: appState.reviewCount,
            ),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: appState.sync,
          child: items.isEmpty
              ? _EmptyState(
                  filter: appState.filter,
                  showEverything: appState.showEverything,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _MailTile(item: items[index]),
                ),
        ),
      );
    },
  );
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.showEverything,
    required this.reviewCount,
  });

  final InboxFilter filter;
  final bool showEverything;
  final int reviewCount;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: <Widget>[
            for (final value in InboxFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: _avatarFor(value),
                  label: Text(
                    // The review count is the number worth surfacing: it is the
                    // pile the user has to decide about, and it grows silently
                    // because nothing about it is notified.
                    value == InboxFilter.needsReview && reviewCount > 0
                        ? '${value.label} ($reviewCount)'
                        : value.label,
                  ),
                  selected: filter == value,
                  onSelected: (_) => appState.setFilter(value),
                ),
              ),
          ],
        ),
      ),
      SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  showEverything
                      ? 'Showing every message, including rejections'
                      : 'Hiding rejections and unrelated mail',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Switch(
                value: showEverything,
                onChanged: appState.setShowEverything,
              ),
            ],
          ),
        ),
      ),
    ],
  );

  static Widget? _avatarFor(InboxFilter filter) {
    final style = switch (filter) {
      InboxFilter.offers => CategoryStyle.of(MailCategory.offer),
      InboxFilter.interviews => CategoryStyle.of(MailCategory.interview),
      InboxFilter.assessments => CategoryStyle.of(MailCategory.assessment),
      InboxFilter.needsReview => const CategoryStyle(
        Color(0xFF9A6A00),
        Icons.help_outline,
      ),
      InboxFilter.all => null,
    };
    if (style == null) return null;
    return Icon(style.icon, size: 18, color: style.color);
  }
}

class _MailTile extends StatelessWidget {
  const _MailTile({required this.item});

  final MailItem item;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.forItem(item);
    final theme = Theme.of(context);
    // Only notified mail gets full visual weight. Review and ignored rows are
    // deliberately quieter so the list still reads at a glance.
    final emphasised = item.verdict == MailVerdict.notify;
    return Dismissible(
      key: ValueKey<int>(item.uid),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: theme.colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.archive_outlined),
      ),
      onDismissed: (_) => appState.archive(item.uid),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: style.color.withValues(alpha: 0.15),
          child: Icon(style.icon, color: style.color, size: 20),
        ),
        title: Text(
          item.subject,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: emphasised ? FontWeight.w600 : FontWeight.w400,
            color: emphasised ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              item.displayFrom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: style.color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    item.displayLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: style.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('score ${item.score}', style: theme.textTheme.labelSmall),
                const Spacer(),
                Text(_formatDate(item.date), style: theme.textTheme.labelSmall),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => MailDetailScreen(item: item),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter, required this.showEverything});

  final InboxFilter filter;
  final bool showEverything;

  @override
  Widget build(BuildContext context) => ListView(
    // A ListView rather than a Center, so RefreshIndicator still works when the
    // list is empty.
    padding: const EdgeInsets.all(32),
    children: <Widget>[
      const SizedBox(height: 80),
      Icon(
        Icons.inbox_outlined,
        size: 56,
        color: Theme.of(context).colorScheme.outline,
      ),
      const SizedBox(height: 16),
      Text(
        switch (filter) {
          InboxFilter.needsReview => 'Nothing waiting for review.',
          InboxFilter.all when showEverything => 'No mail cached yet.',
          InboxFilter.all => 'Nothing flagged yet.',
          _ => 'No ${filter.label.toLowerCase()} yet.',
        },
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        'Pull down to sync. If mail you care about is missing, check the '
        '"Needs review" chip first — it holds anything that scored but was not '
        'decisive enough to notify. Add its exact wording under '
        'Settings → Detection rules to have it notified in future.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
