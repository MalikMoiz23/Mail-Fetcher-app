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

  /// v2 replaced the boolean `is_important` with the three-state `verdict`.
  static const int _version = 2;

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
  }

  /// UIDs already stored, so a sync only classifies genuinely new mail.
  static Future<Set<int>> knownUids() async {
    final db = await _open();
    final rows = await db.query(_table, columns: <String>['uid']);
    return rows.map((Map<String, Object?> row) => row['uid']! as int).toSet();
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
