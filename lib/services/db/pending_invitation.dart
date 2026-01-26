import 'dart:convert';
import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// A pending group invitation (Welcome message) waiting for user acceptance
class PendingInvitation {
  final String id; // Event ID of the Welcome message
  final Map<String, dynamic> welcomeEventJson; // Full Welcome event JSON
  final String? groupIdHex; // NIP-29 group ID from 'g' tag
  final String? inviterPubkey; // Pubkey of the person who invited us (from event.pubkey)
  final DateTime receivedAt; // When we received the invitation

  PendingInvitation({
    required this.id,
    required this.welcomeEventJson,
    this.groupIdHex,
    this.inviterPubkey,
    required this.receivedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'welcome_event_json': jsonEncode(welcomeEventJson),
      'group_id_hex': groupIdHex,
      'inviter_pubkey': inviterPubkey,
      'received_at': receivedAt.millisecondsSinceEpoch,
    };
  }

  factory PendingInvitation.fromMap(Map<String, dynamic> map) {
    return PendingInvitation(
      id: map['id'] as String,
      welcomeEventJson: jsonDecode(map['welcome_event_json'] as String)
          as Map<String, dynamic>,
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
  String get createQuery => '''
    CREATE TABLE IF NOT EXISTS $name (
      id TEXT PRIMARY KEY,
      welcome_event_json TEXT NOT NULL,
      group_id_hex TEXT,
      inviter_pubkey TEXT,
      received_at INTEGER NOT NULL
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Index for querying by group ID
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_invitations_group_id ON $name(group_id_hex)',
    );

    // Index for ordering by received time
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_invitations_received_at ON $name(received_at)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
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
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $name',
    );
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
