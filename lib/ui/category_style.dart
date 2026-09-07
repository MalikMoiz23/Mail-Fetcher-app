import 'package:flutter/material.dart';

import '../models/mail_item.dart';

/// Colour and icon per category, kept in one place so the list, the detail
/// screen and the filter chips cannot drift apart.
///
/// Each style carries two tones. A single fixed colour cannot serve both
/// themes: the greens and blues that read as confident on white lose all their
/// contrast against a dark surface.
class CategoryStyle {
  const CategoryStyle({
    required this.light,
    required this.dark,
    required this.icon,
  });

  final Color light;
  final Color dark;
  final IconData icon;

  Color color(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Tint for a pill or avatar behind [color]. Dark surfaces need a stronger
  /// wash before the tint is visible at all.
  Color container(Brightness brightness) => color(
    brightness,
  ).withValues(alpha: brightness == Brightness.dark ? 0.24 : 0.12);

  static const CategoryStyle _fallback = CategoryStyle(
    light: Color(0xFF5F6368),
    dark: Color(0xFFB6BAC0),
    icon: Icons.mail_outline,
  );

  static const CategoryStyle review = CategoryStyle(
    light: Color(0xFF9A6A00),
    dark: Color(0xFFF2C14E),
    icon: Icons.help_outline,
  );

  static const Map<MailCategory, CategoryStyle> _styles =
      <MailCategory, CategoryStyle>{
        MailCategory.offer: CategoryStyle(
          light: Color(0xFF12703A),
          dark: Color(0xFF6BD48F),
          icon: Icons.workspace_premium_outlined,
        ),
        MailCategory.interview: CategoryStyle(
          light: Color(0xFF1A56C4),
          dark: Color(0xFF8AB4F8),
          icon: Icons.event_available_outlined,
        ),
        MailCategory.assessment: CategoryStyle(
          light: Color(0xFFB35309),
          dark: Color(0xFFFBBC7A),
          icon: Icons.assignment_outlined,
        ),
        MailCategory.recruiter: CategoryStyle(
          light: Color(0xFF6B3FBF),
          dark: Color(0xFFC7A8FF),
          icon: Icons.person_search_outlined,
        ),
        MailCategory.rejection: CategoryStyle(
          light: Color(0xFF7A7A7A),
          dark: Color(0xFF9E9E9E),
          icon: Icons.do_not_disturb_on_outlined,
        ),
        MailCategory.other: _fallback,
      };

  static CategoryStyle of(MailCategory category) =>
      _styles[category] ?? _fallback;

  /// Style for a row, which is driven by the verdict first: "needs review",
  /// "recruiter" and "rejection" say more about how to treat the mail than its
  /// category does.
  static CategoryStyle forItem(MailItem item) => switch (item.verdict) {
    MailVerdict.review => review,
    MailVerdict.informational => of(MailCategory.recruiter),
    MailVerdict.rejected => of(MailCategory.rejection),
    MailVerdict.ignore => _fallback,
    MailVerdict.notify => of(item.category),
  };
}
