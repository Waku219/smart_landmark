import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'landmark.dart';

/// Local single-source-of-truth store.
///
/// Note this class is instantiated in *two* isolates: the UI isolate and the
/// WorkManager background isolate. They each hold their own connection to the
/// same file, which sqlite handles via file locking. Keep writes short and
/// avoid long-running transactions so the two don't block each other.
class DBHelper {
  static final DBHelper _instance = DBHelper._internal();
  factory DBHelper() => _instance;
  DBHelper._internal();

  /// Give up on a queued item after this many failed attempts, so a row that
  /// can never succeed doesn't get retried on every 15-minute tick forever.
  static const int maxRetries = 10;

  static void _log(String message) => debugPrint('[DB] $message');

  Future<Database>? _openFuture;

  /// Memoises the *future*, not just the resulting Database.
  ///
  /// MapScreen and LandmarksListScreen both call this from initState in the
  /// same frame. With a plain `if (_database != null)` null check, both saw
  /// null and each kicked off its own `_initDB()`, so the same file was opened
  /// twice concurrently and the two runs raced each other through onUpgrade's
  /// ALTER TABLE statements. Holding a single in-flight future means the
  /// second caller waits on the first instead of duplicating the work.
  Future<Database> get database => _openFuture ??= _open();

  Future<Database> _open() async {
    try {
      final db = await _initDB();
      _log('database ready');
      return db;
    } catch (e, stack) {
      _log('database open FAILED: $e\n$stack');
      // Drop the cached future so a later retry gets a fresh attempt rather
      // than replaying the same failure forever.
      _openFuture = null;
      rethrow;
    }
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'smart_landmarks.db');

    return await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE landmarks(
            id INTEGER PRIMARY KEY,
            title TEXT,
            lat REAL,
            lon REAL,
            image TEXT,
            score REAL,
            isActive INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE pending_visits(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            landmarkId INTEGER,
            landmarkTitle TEXT,
            lat REAL,
            lon REAL,
            createdAt TEXT,
            retryCount INTEGER NOT NULL DEFAULT 0
          )
        ''');

        await _createV2Tables(db);
        await _applyV3Columns(db, freshInstall: true);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        _log('upgrading schema $oldVersion -> $newVersion');
        if (oldVersion < 2) {
          await _createV2Tables(db);
        }
        if (oldVersion < 3) {
          await _applyV3Columns(db, freshInstall: false);
        }
      },
    );
  }

  Future<void> _createV2Tables(Database db) async {
    // Jobs that have been accepted by the server (job_id returned) and are
    // still being polled for a result. This is the single table that both
    // the "visit while online" flow and the "drain the offline queue" flow
    // feed into, so one WorkManager task can poll all of them.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_jobs(
        jobId INTEGER PRIMARY KEY,
        landmarkTitle TEXT,
        createdAt TEXT
      )
    ''');

    // Completed visits, written by the background worker so the Activity
    // screen has something durable to read even if the app was killed
    // while the job was in flight.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS visit_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        landmarkTitle TEXT,
        distance REAL,
        visitTime TEXT
      )
    ''');
  }

  /// v3 adds:
  ///  - retryCount on both queues, so a permanently-failing row can be dropped
  ///  - visitedAt on pending_jobs, so the Activity screen can show *when the
  ///    user actually visited* rather than when the worker happened to run
  ///    (these differ by hours for a visit queued offline overnight)
  ///  - status on visit_history, so a failed job leaves a visible trace
  ///    instead of disappearing silently
  Future<void> _applyV3Columns(Database db, {required bool freshInstall}) async {
    Future<void> addColumn(String table, String definition) async {
      try {
        await db.execute('ALTER TABLE $table ADD COLUMN $definition');
      } catch (e) {
        // "duplicate column name" — already applied, nothing to do. Caught
        // broadly on purpose: a migration must never be able to bring down
        // the whole database open.
        _log('skip ALTER $table ($e)');
      }
    }

    if (!freshInstall) {
      await addColumn('pending_visits', 'retryCount INTEGER NOT NULL DEFAULT 0');
    }
    await addColumn('pending_jobs', 'retryCount INTEGER NOT NULL DEFAULT 0');
    await addColumn('pending_jobs', 'visitedAt TEXT');
    await addColumn('visit_history', "status TEXT NOT NULL DEFAULT 'done'");
  }

  // --- landmarks cache ---

  Future<void> cacheLandmarks(List<Landmark> landmarks) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('landmarks'); // clear the old cache, then repopulate
    for (var landmark in landmarks) {
      batch.insert(
        'landmarks',
        landmark.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Landmark>> getCachedLandmarks() async {
    final db = await database;
    final maps = await db.query('landmarks');
    return maps.map((map) => Landmark.fromMap(map)).toList();
  }

  /// Merges a fresh (always active-only) list from get_landmarks with
  /// whatever is currently cached, so landmarks the user soft-deleted
  /// locally aren't silently "undeleted" by the next refresh (the server
  /// never lists deleted landmarks, so we're the only record of them).
  /// Caches and returns the merged list.
  Future<List<Landmark>> mergeAndCacheLandmarks(
    List<Landmark> freshFromServer,
  ) async {
    final cached = await getCachedLandmarks();
    final locallyDeletedIds =
        cached.where((l) => !l.isActive).map((l) => l.id).toSet();

    final merged = [
      ...freshFromServer.where((l) => !locallyDeletedIds.contains(l.id)),
      ...cached.where((l) => locallyDeletedIds.contains(l.id)),
    ];

    await cacheLandmarks(merged);
    return merged;
  }

  // --- pending_visits: visits captured while offline, not yet submitted ---

  Future<int> addPendingVisit(
    int landmarkId,
    String landmarkTitle,
    double lat,
    double lon,
  ) async {
    final db = await database;
    final id = await db.insert('pending_visits', {
      'landmarkId': landmarkId,
      'landmarkTitle': landmarkTitle,
      'lat': lat,
      'lon': lon,
      'createdAt': DateTime.now().toIso8601String(),
      'retryCount': 0,
    });
    _log('queued offline visit #$id for "$landmarkTitle"');
    return id;
  }

  Future<List<Map<String, dynamic>>> getPendingVisits() async {
    final db = await database;
    return await db.query('pending_visits', orderBy: 'createdAt ASC');
  }

  Future<int> getPendingVisitCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_visits',
    );
    return (rows.first['c'] as num).toInt();
  }

  Future<void> deletePendingVisit(int id) async {
    final db = await database;
    await db.delete('pending_visits', where: 'id = ?', whereArgs: [id]);
  }

  /// Bumps the attempt counter and drops the row once it's clearly hopeless.
  /// Returns true if the row was given up on.
  Future<bool> bumpPendingVisitRetry(int id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE pending_visits SET retryCount = retryCount + 1 WHERE id = ?',
      [id],
    );
    final rows = await db.query(
      'pending_visits',
      columns: ['retryCount'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return false;
    final count = (rows.first['retryCount'] as num).toInt();
    if (count >= maxRetries) {
      _log('giving up on queued visit #$id after $count attempts');
      await deletePendingVisit(id);
      return true;
    }
    return false;
  }

  // --- pending_jobs: visit jobs waiting on get_job_status to resolve ---

  Future<void> addPendingJob(
    int jobId,
    String landmarkTitle, {
    DateTime? visitedAt,
  }) async {
    final db = await database;
    await db.insert(
      'pending_jobs',
      {
        'jobId': jobId,
        'landmarkTitle': landmarkTitle,
        'createdAt': DateTime.now().toIso8601String(),
        // The moment the *user* made the visit. For an online visit that's
        // now; for one drained off the offline queue it's when it was queued.
        'visitedAt': (visitedAt ?? DateTime.now()).toIso8601String(),
        'retryCount': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log('tracking job #$jobId for "$landmarkTitle"');
  }

  Future<List<Map<String, dynamic>>> getPendingJobs() async {
    final db = await database;
    return await db.query('pending_jobs', orderBy: 'createdAt ASC');
  }

  Future<int> getPendingJobCount() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM pending_jobs');
    return (rows.first['c'] as num).toInt();
  }

  Future<void> deletePendingJob(int jobId) async {
    final db = await database;
    await db.delete('pending_jobs', where: 'jobId = ?', whereArgs: [jobId]);
  }

  Future<bool> bumpPendingJobRetry(int jobId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE pending_jobs SET retryCount = retryCount + 1 WHERE jobId = ?',
      [jobId],
    );
    final rows = await db.query(
      'pending_jobs',
      columns: ['retryCount'],
      where: 'jobId = ?',
      whereArgs: [jobId],
    );
    if (rows.isEmpty) return false;
    final count = (rows.first['retryCount'] as num).toInt();
    if (count >= maxRetries) {
      _log('giving up on job #$jobId after $count polls');
      await deletePendingJob(jobId);
      return true;
    }
    return false;
  }

  // --- visit_history: resolved visits, written by the background worker ---

  Future<void> addVisitRecord(
    String landmarkTitle,
    double? distance, {
    DateTime? visitedAt,
    String status = 'done',
  }) async {
    final db = await database;
    await db.insert('visit_history', {
      'landmarkTitle': landmarkTitle,
      'distance': distance,
      'visitTime': (visitedAt ?? DateTime.now()).toIso8601String(),
      'status': status,
    });
    _log('recorded $status visit "$landmarkTitle" distance=$distance');
  }

  Future<List<Map<String, dynamic>>> getVisitHistory() async {
    final db = await database;
    return await db.query('visit_history', orderBy: 'visitTime DESC');
  }

  // --- local mirror of soft delete/restore (server never lists deleted
  // landmarks via get_landmarks, so we have to remember locally which ones
  // *we* deleted in order to offer a Restore action) ---

  Future<void> setLandmarkActive(int id, bool isActive) async {
    final db = await database;
    await db.update(
      'landmarks',
      {'isActive': isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
