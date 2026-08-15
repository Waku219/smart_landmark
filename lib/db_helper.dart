import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'landmark.dart';

class DBHelper {
  static final DBHelper _instance = DBHelper._internal();
  factory DBHelper() => _instance;
  DBHelper._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'smart_landmarks.db');

    return await openDatabase(
      path,
      version: 1,
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
            createdAt TEXT
          )
        ''');
      },
    );
  }
  Future<void> cacheLandmarks(List<Landmark> landmarks) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('landmarks'); // পুরনো cache মুছে নতুন করে বসাই
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

  Future<int> addPendingVisit(int landmarkId, String landmarkTitle, double lat, double lon) async {
    final db = await database;
    return await db.insert('pending_visits', {
      'landmarkId': landmarkId,
      'landmarkTitle': landmarkTitle,
      'lat': lat,
      'lon': lon,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getPendingVisits() async {
    final db = await database;
    return await db.query('pending_visits');
  }

  Future<void> deletePendingVisit(int id) async {
    final db = await database;
    await db.delete('pending_visits', where: 'id = ?', whereArgs: [id]);
  }
}