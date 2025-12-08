import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// Model for a cached decrypted media entry
class DecryptedMediaCacheEntry {
  /// SHA-256 hash of the encrypted blob (primary key)
  final String sha256;

  /// Local file path to the decrypted image
  final String localPath;

  /// MLS group ID used for decryption
  final String groupId;

  /// Timestamp when the entry was created
  final DateTime createdAt;

  const DecryptedMediaCacheEntry({
    required this.sha256,
    required this.localPath,
    required this.groupId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'sha256': sha256,
      'local_path': localPath,
      'group_id': groupId,
      'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
    };
  }

  factory DecryptedMediaCacheEntry.fromMap(Map<String, dynamic> map) {
    return DecryptedMediaCacheEntry(
      sha256: map['sha256'] as String,
      localPath: map['local_path'] as String,
      groupId: map['group_id'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }
}

/// Database table for caching decrypted media local paths
class DecryptedMediaCacheTable extends DBTable {
  DecryptedMediaCacheTable(super.db);

  @override
  String get name => 'decrypted_media_cache';

  @override
  String get createQuery => '''
    CREATE TABLE IF NOT EXISTS $name (
      sha256 TEXT PRIMARY KEY,
      local_path TEXT NOT NULL,
      group_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Create index for group_id lookups
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_decrypted_media_cache_group_id ON $name(group_id)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Insert or update a cache entry
  Future<void> insert(DecryptedMediaCacheEntry entry) async {
    await db.insert(
      name,
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get a cache entry by SHA-256 hash
  Future<DecryptedMediaCacheEntry?> getBySha256(String sha256) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'sha256 = ?',
      whereArgs: [sha256],
    );

    if (maps.isEmpty) return null;
    return DecryptedMediaCacheEntry.fromMap(maps.first);
  }

  /// Get the local path for a cached entry, or null if not cached
  Future<String?> getLocalPath(String sha256) async {
    final entry = await getBySha256(sha256);
    return entry?.localPath;
  }

  /// Get all cache entries for a specific group
  Future<List<DecryptedMediaCacheEntry>> getByGroupId(String groupId) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'created_at DESC',
    );

    return maps.map((map) => DecryptedMediaCacheEntry.fromMap(map)).toList();
  }

  /// Get all cache entries as a map of sha256 -> localPath
  Future<Map<String, String>> getAllAsMap() async {
    final List<Map<String, dynamic>> maps = await db.query(name);

    final result = <String, String>{};
    for (final map in maps) {
      result[map['sha256'] as String] = map['local_path'] as String;
    }
    return result;
  }

  /// Get all cache entries for a group as a map of sha256 -> localPath
  Future<Map<String, String>> getGroupCacheMap(String groupId) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ?',
      whereArgs: [groupId],
    );

    final result = <String, String>{};
    for (final map in maps) {
      result[map['sha256'] as String] = map['local_path'] as String;
    }
    return result;
  }

  /// Delete a cache entry
  Future<void> delete(String sha256) async {
    await db.delete(name, where: 'sha256 = ?', whereArgs: [sha256]);
  }

  /// Delete all cache entries for a group
  Future<void> deleteByGroupId(String groupId) async {
    await db.delete(name, where: 'group_id = ?', whereArgs: [groupId]);
  }

  /// Clear all cache entries
  Future<void> clear() async {
    await db.delete(name);
  }

  /// Get the total number of cached entries
  Future<int> count() async {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $name');
    return result.first['count'] as int;
  }

  /// Delete entries older than a certain date (for cache cleanup)
  Future<int> deleteOlderThan(DateTime date) async {
    return await db.delete(
      name,
      where: 'created_at < ?',
      whereArgs: [date.millisecondsSinceEpoch ~/ 1000],
    );
  }
}

