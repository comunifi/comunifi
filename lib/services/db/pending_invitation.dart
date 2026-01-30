import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// A pending group invitation (kind:9009 invite event) waiting for user acceptance
class PendingInvitation {
  final String id; // Event ID of the invite event (kind:9009)
  final Map<String, dynamic>
  inviteEventJson; // Full invite event JSON (kind:9009)
  final String? groupIdHex; // NIP-29 group ID from 'h' tag
  final String?
  inviterPubkey; // Pubkey of the person who invited us (from event.pubkey)
  final DateTime receivedAt; // When we received the invitation

  PendingInvitation({
    required this.id,
    required this.inviteEventJson,
    this.groupIdHex,
    this.inviterPubkey,
    required this.receivedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'invite_event_json': jsonEncode(inviteEventJson),
      'group_id_hex': groupIdHex,
      'inviter_pubkey': inviterPubkey,
      'received_at': receivedAt.millisecondsSinceEpoch,
    };
  }

  factory PendingInvitation.fromMap(Map<String, dynamic> map) {
    // Support both old column name (welcome_event_json) and new (invite_event_json) for migration
    final eventJsonKey = map.containsKey('invite_event_json')
        ? 'invite_event_json'
        : 'welcome_event_json';

    return PendingInvitation(
      id: map['id'] as String,
      inviteEventJson:
          jsonDecode(map[eventJsonKey] as String) as Map<String, dynamic>,
      groupIdHex: map['group_id_hex'] as String?,
      inviterPubkey: map['inviter_pubkey'] as String?,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        map['received_at'] as int,
      ),
    );
  }
}

/// Table for storing pending group invitations that haven't been accepted/rejected yet
class PendingInvitationTable extends DBTable {
  PendingInvitationTable(super.db);

  @override
  String get name => 'pending_invitations';

  @override
  String get createQuery =>
      '''
    CREATE TABLE IF NOT EXISTS $name (
      id TEXT PRIMARY KEY,
      invite_event_json TEXT NOT NULL,
      group_id_hex TEXT,
      inviter_pubkey TEXT,
      received_at INTEGER NOT NULL
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Ensure schema is correct (handle case where table exists but is missing columns)
    await _ensureSchema(db);

    // Index for querying by group ID
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_invitations_group_id ON $name(group_id_hex)',
    );

    // Index for ordering by received time
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_invitations_received_at ON $name(received_at)',
    );
  }

  /// Ensure the table schema is correct, adding missing columns if needed
  Future<void> _ensureSchema(Database db) async {
    try {
      // Check what columns exist
      final tableInfo = await db.rawQuery("PRAGMA table_info($name)");
      final columnNames = tableInfo.map((row) => row['name'] as String).toList();
      final hasOldColumn = columnNames.contains('welcome_event_json');
      final hasNewColumn = columnNames.contains('invite_event_json');

      if (hasOldColumn && !hasNewColumn) {
        // Rename column from welcome_event_json to invite_event_json
        await db.execute(
          'ALTER TABLE $name RENAME COLUMN welcome_event_json TO invite_event_json',
        );
        debugPrint(
          'Fixed pending_invitations table: renamed welcome_event_json to invite_event_json',
        );
      } else if (!hasOldColumn && !hasNewColumn) {
        // Neither column exists - add the new column
        // Use a default empty JSON object for existing rows
        try {
          await db.execute(
            'ALTER TABLE $name ADD COLUMN invite_event_json TEXT NOT NULL DEFAULT \'{}\'',
          );
          debugPrint(
            'Fixed pending_invitations table: added missing invite_event_json column',
          );
        } catch (e) {
          // If adding column fails (e.g., NOT NULL constraint), make it nullable first
          debugPrint(
            'Failed to add NOT NULL column, trying nullable: $e',
          );
          await db.execute(
            'ALTER TABLE $name ADD COLUMN invite_event_json TEXT',
          );
          // Update existing rows to have empty JSON
          await db.execute(
            'UPDATE $name SET invite_event_json = \'{}\' WHERE invite_event_json IS NULL',
          );
          // Now make it NOT NULL (SQLite doesn't support this directly, but we'll handle it in code)
          debugPrint(
            'Fixed pending_invitations table: added invite_event_json column (nullable)',
          );
        }
      }
    } catch (e) {
      debugPrint(
        'Error ensuring schema for pending_invitations table: $e',
      );
      // Don't rethrow - table creation will continue
    }
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Ensure schema is correct
    await _ensureSchema(db);
  }

  /// Add a pending invitation
  Future<void> add(PendingInvitation invitation) async {
    await db.insert(
      name,
      invitation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all pending invitations, ordered by received time (newest first)
  Future<List<PendingInvitation>> getAll() async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      orderBy: 'received_at DESC',
    );

    return maps.map((m) => PendingInvitation.fromMap(m)).toList();
  }

  /// Get count of pending invitations
  Future<int> getCount() async {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $name');
    return result.first['count'] as int;
  }

  /// Get invitation by ID
  Future<PendingInvitation?> getById(String id) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return PendingInvitation.fromMap(maps.first);
  }

  /// Remove an invitation (after accept/reject)
  Future<void> remove(String id) async {
    await db.delete(name, where: 'id = ?', whereArgs: [id]);
  }

  /// Check if invitation exists for a group
  Future<bool> existsForGroup(String groupIdHex) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $name WHERE group_id_hex = ?',
      [groupIdHex],
    );
    return (result.first['count'] as int) > 0;
  }

  /// Clear all pending invitations
  Future<void> clear() async {
    await db.delete(name);
  }
}
