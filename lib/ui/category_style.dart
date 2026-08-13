import 'package:flutter/material.dart';

import '../models/mail_item.dart';

/// Colour and icon per category, kept in one place so the list, the detail
/// screen and the filter chips cannot drift apart.
class CategoryStyle {
  const CategoryStyle(this.color, this.icon);

  final Color color;
  final IconData icon;

  static const CategoryStyle _fallback = CategoryStyle(
    Color(0xFF6B6B6B),
    Icons.mail_outline,
  );

  static const CategoryStyle _review = CategoryStyle(
    Color(0xFF9A6A00),
    Icons.help_outline,
  );

  static const Map<MailCategory, CategoryStyle> _styles =
      <MailCategory, CategoryStyle>{
        MailCategory.offer: CategoryStyle(Color(0xFF1B873F), Icons.verified),
        MailCategory.interview: CategoryStyle(
          Color(0xFF1A73E8),
          Icons.event_available,
        ),
        MailCategory.assessment: CategoryStyle(
          Color(0xFFE8710A),
          Icons.assignment_outlined,
        ),
        MailCategory.recruiter: CategoryStyle(
          Color(0xFF7B4FCF),
          Icons.person_search_outlined,
        ),
        MailCategory.rejection: CategoryStyle(
          Color(0xFF8A8A8A),
          Icons.do_not_disturb_on_outlined,
        ),
        MailCategory.other: _fallback,
      };

  static CategoryStyle of(MailCategory category) =>
      _styles[category] ?? _fallback;

  /// Style for a row, which is driven by the verdict first: "needs review" and
  /// "rejection" say more about how to treat the mail than its category does.
  static CategoryStyle forItem(MailItem item) => switch (item.verdict) {
    MailVerdict.review => _review,
    MailVerdict.rejected => of(MailCategory.rejection),
    MailVerdict.ignore => _fallback,
    MailVerdict.notify => of(item.category),
  };
}
