import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/mail_item.dart';
import 'classifier.dart';

/// Local cache of classified mail.
///
/// Two things depend on it: the list the UI shows without a network round trip,
/// and the `notified` flag that stops a background sync from re-notifying the
/// same message every 15 minutes.
class MailDatabase {
  const MailDatabase._();

  static const String _table = 'mails';

  /// v2 replaced the boolean `is_important` with a three-state `verdict`.
  /// v3 added the `informational` verdict, so every cached row has to be
  /// rescored by the current rules rather than reinterpreted.
  static const int _version = 3;

  static Database? _db;

  static Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    final path = p.join(await getDatabasesPath(), 'mail_fetching_app.db');
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: (Database db, int version) => _createSchema(db),
      onUpgrade: (Database db, int from, int to) async {
        // The table is a rebuildable cache of the last few hundred messages, so
        // recreating it costs one sync and avoids hand-written column
        // migrations. Manual verdict overrides are lost; that is the tradeoff.
        await db.execute('DROP TABLE IF EXISTS $_table');
        await _createSchema(db);
      },
    );
    _db = db;
    return db;
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE $_table (
        uid           INTEGER PRIMARY KEY,
        message_id    TEXT    NOT NULL,
        subject       TEXT    NOT NULL,
        from_name     TEXT    NOT NULL,
        from_email    TEXT    NOT NULL,
        date_ms       INTEGER NOT NULL,
        body          TEXT    NOT NULL,
        category      TEXT    NOT NULL,
        score         INTEGER NOT NULL,
        reasons       TEXT    NOT NULL,
        verdict       TEXT    NOT NULL,
        notified      INTEGER NOT NULL DEFAULT 0,
        archived      INTEGER NOT NULL DEFAULT 0,
        user_override INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_mails_verdict_date ON $_table (verdict, date_ms DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_mails_category_date ON $_table (category, date_ms DESC)',
    );
  }

  /// Whether the cache holds anything at all.
  ///
  /// The sync uses this to decide it needs a fresh baseline: a stored UID
  /// cursor with an empty table would otherwise leave the list blank until new
  /// mail happened to arrive, which is exactly what a schema rebuild causes.
  static Future<int> rowCount() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $_table');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Highest stored UID, used to recover the sync cursor when the stored one is
  /// missing but the cache is not.
  static Future<int?> highestUid() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT MAX(uid) AS m FROM $_table');
    return rows.first['m'] as int?;
  }

  static Future<MailItem?> byUid(int uid) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'uid = ?',
      whereArgs: <Object?>[uid],
      limit: 1,
    );
    return rows.isEmpty ? null : MailItem.fromMap(rows.first);
  }

  /// Inserts only rows whose UID is new. Existing rows keep their `notified`,
  /// `archived` and `user_override` flags, which an upsert would clobber.
  static Future<void> insertNew(List<MailItem> items) async {
    if (items.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final item in items) {
      batch.insert(
        _table,
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Mail that earned a notification and has not had one yet, oldest first so a
  /// backlog arrives in chronological order.
  ///
  /// Only [MailVerdict.notify] qualifies: "needs review" exists precisely so
  /// that ambiguous mail is visible without interrupting the user.
  static Future<List<MailItem>> pendingNotifications() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'verdict = ? AND notified = 0 AND archived = 0',
      whereArgs: <Object?>[MailVerdict.notify.name],
      orderBy: 'date_ms ASC',
    );
    return rows.map(MailItem.fromMap).toList(growable: false);
  }

  static Future<void> markNotified(Iterable<int> uids) async {
    if (uids.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final uid in uids) {
      batch.update(
        _table,
        <String, Object?>{'notified': 1},
        where: 'uid = ?',
        whereArgs: <Object?>[uid],
      );
    }
    await batch.commit(noResult: true);
  }

  /// [verdicts] must be non-empty; pass every verdict to show everything,
  /// including rejections, so the user can audit what was filtered out.
  static Future<List<MailItem>> list({
    required Set<MailVerdict> verdicts,
    MailCategory? category,
    bool includeArchived = false,
    String query = '',
  }) async {
    if (verdicts.isEmpty) return const <MailItem>[];
    final db = await _open();
    final placeholders = List<String>.filled(verdicts.length, '?').join(', ');
    final clauses = <String>['verdict IN ($placeholders)'];
    final args = <Object?>[
      ...verdicts.map((MailVerdict verdict) => verdict.name),
    ];
    if (!includeArchived) clauses.add('archived = 0');
    if (category != null) {
      clauses.add('category = ?');
      args.add(category.name);
    }
    final needle = query.trim();
    if (needle.isNotEmpty) {
      // Searching in SQL rather than filtering the loaded page means the whole
      // cache is searchable, not just the newest few hundred rows.
      clauses.add(
        '(subject LIKE ? OR from_name LIKE ? OR from_email LIKE ? '
        'OR body LIKE ?)',
      );
      final pattern = '%$needle%';
      args.addAll(<Object?>[pattern, pattern, pattern, pattern]);
    }
    final rows = await db.query(
      _table,
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'date_ms DESC',
      limit: 500,
    );
    return rows.map(MailItem.fromMap).toList(growable: false);
  }

  static Future<void> setArchived({
    required int uid,
    required bool archived,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      <String, Object?>{'archived': archived ? 1 : 0},
      where: 'uid = ?',
      whereArgs: <Object?>[uid],
    );
  }

  /// Manual correction. Sets `user_override` so a later rules change or
  /// re-classification does not undo the user's decision.
  static Future<void> setVerdict({
    required int uid,
    required MailVerdict verdict,
  }) async {
    final db = await _open();
    await db.update(
      _table,
      <String, Object?>{'verdict': verdict.name, 'user_override': 1},
      where: 'uid = ?',
      whereArgs: <Object?>[uid],
    );
  }

  /// Rescores every cached mail against the current rules. Rows the user has
  /// corrected by hand are skipped.
  ///
  /// `notified` is deliberately left untouched: it records whether a
  /// notification was ever actually posted. That way mail promoted from "needs
  /// review" to "flagged" by a rules change still gets its notification, while
  /// mail that already fired never fires twice.
  static Future<int> reclassifyAll(
    Classification Function(MailItem item) classify,
  ) async {
    final db = await _open();
    final rows = await db.query(_table, where: 'user_override = 0');
    final items = rows.map(MailItem.fromMap).toList(growable: false);
    var changed = 0;
    final batch = db.batch();
    for (final item in items) {
      final verdict = classify(item);
      if (verdict.verdict == item.verdict &&
          verdict.category == item.category &&
          verdict.score == item.score) {
        continue;
      }
      changed++;
      batch.update(
        _table,
        <String, Object?>{
          'category': verdict.category.name,
          'score': verdict.score,
          'reasons': verdict.reasons.join('\n'),
          'verdict': verdict.verdict.name,
        },
        where: 'uid = ?',
        whereArgs: <Object?>[item.uid],
      );
    }
    await batch.commit(noResult: true);
    return changed;
  }

  /// Number of rows per verdict, for the filter-chip counts.
  static Future<Map<MailVerdict, int>> countsByVerdict() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT verdict, COUNT(*) AS n FROM $_table '
      'WHERE archived = 0 GROUP BY verdict',
    );
    return <MailVerdict, int>{
      for (final row in rows)
        MailVerdict.byName(row['verdict']! as String): row['n']! as int,
    };
  }

  /// Number of flagged rows per category, for the per-category chip counts.
  /// Only notified mail is counted, because that is what those chips show.
  static Future<Map<MailCategory, int>> countsByCategory() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT category, COUNT(*) AS n FROM $_table '
      'WHERE archived = 0 AND verdict = ? GROUP BY category',
      <Object?>[MailVerdict.notify.name],
    );
    return <MailCategory, int>{
      for (final row in rows)
        MailCategory.byName(row['category']! as String): row['n']! as int,
    };
  }

  /// Rows the user archived, newest first. Kept for the archive view so a swipe
  /// is recoverable long after the undo snackbar has gone.
  static Future<List<MailItem>> archived() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'archived = 1',
      orderBy: 'date_ms DESC',
      limit: 200,
    );
    return rows.map(MailItem.fromMap).toList(growable: false);
  }

  /// Drops the oldest rows beyond [keep].
  ///
  /// Rows hold the full classified body, so without this the database grows
  /// without bound for as long as the app is installed.
  static Future<int> prune({int keep = 1000}) async {
    final db = await _open();
    return db.rawDelete(
      'DELETE FROM $_table WHERE uid NOT IN ('
      'SELECT uid FROM $_table ORDER BY date_ms DESC LIMIT ?)',
      <Object?>[keep],
    );
  }

  static Future<void> wipe() async {
    final db = await _open();
    await db.delete(_table);
  }
}
