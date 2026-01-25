import 'dart:convert';
import 'package:comunifi/services/db/db.dart';
import 'package:comunifi/services/nostr/group_channel.dart';
import 'package:sqflite_common/sqflite.dart';

/// Database table for storing channel metadata (GroupChannelMetadata)
/// Persists channels and their pinned/order state across app restarts
class ChannelMetadataTable extends DBTable {
  ChannelMetadataTable(super.db);

  @override
  String get name => 'channel_metadata';

  @override
  String get createQuery => '''
    CREATE TABLE IF NOT EXISTS $name (
      group_id TEXT NOT NULL,
      channel_id TEXT NOT NULL,
      name TEXT NOT NULL,
      about TEXT,
      picture TEXT,
      relays TEXT NOT NULL,
      creator TEXT NOT NULL,
      extra TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (group_id, channel_id)
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Create index for group_id lookups
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_channel_metadata_group_id ON $name(group_id)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Insert or update a channel metadata entry
  Future<void> insertOrUpdate(GroupChannelMetadata channel) async {
    final now = DateTime.now();
    await db.insert(
      name,
      {
        'group_id': channel.groupId,
        'channel_id': channel.id,
        'name': channel.name,
        'about': channel.about,
        'picture': channel.picture,
        'relays': jsonEncode(channel.relays),
        'creator': channel.creator,
        'extra': channel.extra != null ? jsonEncode(channel.extra) : null,
        'created_at': channel.createdAt.millisecondsSinceEpoch ~/ 1000,
        'updated_at': now.millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all channels for a specific group
  Future<List<GroupChannelMetadata>> getByGroupId(String groupIdHex) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ?',
      whereArgs: [groupIdHex],
      orderBy: 'created_at ASC',
    );

    return maps.map((map) => _fromMap(map)).toList();
  }

  /// Get a specific channel by group ID and channel ID
  Future<GroupChannelMetadata?> getByChannelId(
    String groupIdHex,
    String channelId,
  ) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ? AND channel_id = ?',
      whereArgs: [groupIdHex, channelId],
    );

    if (maps.isEmpty) return null;
    return _fromMap(maps.first);
  }

  /// Delete all channels for a specific group
  Future<void> deleteByGroupId(String groupIdHex) async {
    await db.delete(
      name,
      where: 'group_id = ?',
      whereArgs: [groupIdHex],
    );
  }

  /// Delete a specific channel
  Future<void> deleteByChannelId(String groupIdHex, String channelId) async {
    await db.delete(
      name,
      where: 'group_id = ? AND channel_id = ?',
      whereArgs: [groupIdHex, channelId],
    );
  }

  /// Clear all channel metadata
  Future<void> clear() async {
    await db.delete(name);
  }

  /// Get the total number of channels
  Future<int> count() async {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $name');
    return result.first['count'] as int;
  }

  /// Convert database map to GroupChannelMetadata
  GroupChannelMetadata _fromMap(Map<String, dynamic> map) {
    // Parse relays from JSON
    List<String> relays = [];
    try {
      final relaysJson = jsonDecode(map['relays'] as String);
      if (relaysJson is List) {
        relays = relaysJson.map((r) => r.toString()).toList();
      }
    } catch (e) {
      // Fallback to empty list if parsing fails
      relays = [];
    }

    // Parse extra from JSON
    Map<String, dynamic>? extra;
    if (map['extra'] != null) {
      try {
        extra = Map<String, dynamic>.from(
          jsonDecode(map['extra'] as String) as Map,
        );
      } catch (e) {
        // Fallback to null if parsing fails
        extra = null;
      }
    }

    return GroupChannelMetadata(
      id: map['channel_id'] as String,
      groupId: map['group_id'] as String,
      name: map['name'] as String,
      about: map['about'] as String?,
      picture: map['picture'] as String?,
      relays: relays,
      creator: map['creator'] as String,
      extra: extra,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }
}
