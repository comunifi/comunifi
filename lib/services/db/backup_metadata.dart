import 'package:comunifi/services/backup/backup_models.dart';
import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// Table for tracking MLS group backup state
/// Stores metadata about when each group was last backed up
/// and whether changes have been made since
class BackupMetadataTable extends DBTable {
  BackupMetadataTable(super.db);

  @override
  String get name => 'backup_metadata';

  @override
  String get createQuery =>
      '''
    CREATE TABLE IF NOT EXISTS $name (
      group_id TEXT PRIMARY KEY,
      last_backup_timestamp INTEGER,
      last_backup_state_hash TEXT,
      is_dirty INTEGER NOT NULL DEFAULT 1
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Create index for efficient dirty check queries
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_backup_metadata_dirty ON $name(is_dirty)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Get backup metadata for a specific group
  Future<BackupMetadata?> getByGroupId(String groupId) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ?',
      whereArgs: [groupId],
    );

    if (maps.isEmpty) return null;
    return BackupMetadata.fromMap(maps.first);
  }

  /// Get all backup metadata entries
  Future<List<BackupMetadata>> getAll() async {
    final List<Map<String, dynamic>> maps = await db.query(name);
    return maps.map((map) => BackupMetadata.fromMap(map)).toList();
  }

  /// Get all groups that need backup (never backed up or dirty)
  Future<List<BackupMetadata>> getPendingBackups() async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'is_dirty = 1 OR last_backup_timestamp IS NULL',
    );
    return maps.map((map) => BackupMetadata.fromMap(map)).toList();
  }

  /// Check if any backups are pending
  Future<bool> hasPendingBackups() async {
    final pending = await getPendingBackups();
    return pending.isNotEmpty;
  }

  /// Get the most recent backup timestamp across all groups
  Future<DateTime?> getLastBackupTime() async {
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT MAX(last_backup_timestamp) as max_ts FROM $name WHERE last_backup_timestamp IS NOT NULL',
    );

    if (maps.isEmpty || maps.first['max_ts'] == null) return null;

    final timestamp = maps.first['max_ts'] as int;
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }

  /// Insert or update backup metadata for a group
  Future<void> upsert(BackupMetadata metadata) async {
    await db.insert(
      name,
      metadata.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Mark a group as backed up (clear dirty flag, update timestamp and hash)
  Future<void> markBackedUp(
    String groupId, {
    required int timestamp,
    String? stateHash,
  }) async {
    final existing = await getByGroupId(groupId);

    if (existing != null) {
      await db.update(
        name,
        {
          'last_backup_timestamp': timestamp,
          'last_backup_state_hash': stateHash,
          'is_dirty': 0,
        },
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
    } else {
      await upsert(
        BackupMetadata(
          groupId: groupId,
          lastBackupTimestamp: timestamp,
          lastBackupStateHash: stateHash,
          isDirty: false,
        ),
      );
    }
  }

  /// Mark a group as dirty (needs backup due to state change)
  Future<void> markDirty(String groupId) async {
    final existing = await getByGroupId(groupId);

    if (existing != null) {
      await db.update(
        name,
        {'is_dirty': 1},
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
    } else {
      // Create new entry for a group we haven't tracked yet
      await upsert(BackupMetadata(groupId: groupId, isDirty: true));
    }
  }

  /// Ensure a group exists in the tracking table
  /// Creates entry if not exists, does nothing if exists
  Future<void> ensureExists(String groupId) async {
    final existing = await getByGroupId(groupId);
    if (existing == null) {
      await upsert(BackupMetadata(groupId: groupId, isDirty: true));
    }
  }

  /// Delete backup metadata for a group
  Future<void> delete(String groupId) async {
    await db.delete(name, where: 'group_id = ?', whereArgs: [groupId]);
  }

  /// Clear all backup metadata
  Future<void> clear() async {
    await db.delete(name);
  }

  /// Get backup status summary
  Future<BackupStatus> getBackupStatus() async {
    final all = await getAll();
    final pending = all.where((m) => m.needsBackup).toList();
    final lastBackup = await getLastBackupTime();

    return BackupStatus(
      lastBackupTime: lastBackup,
      pendingCount: pending.length,
      totalGroups: all.length,
    );
  }
}
