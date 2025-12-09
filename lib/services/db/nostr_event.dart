import 'dart:convert';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// Table for storing Nostr events with efficient tag querying.
/// All tag operations are handled automatically - you only need to use this class.
class NostrEventTable extends DBTable {
  NostrEventTable(super.db);

  // Internal tag table instance
  late final _NostrEventTagTable _tagTable = _NostrEventTagTable(this.db);

  @override
  String get name => 'nostr_events';

  @override
  String get createQuery =>
      '''
    CREATE TABLE IF NOT EXISTS $name (
      id TEXT PRIMARY KEY,
      pubkey TEXT NOT NULL,
      kind INTEGER NOT NULL,
      content TEXT NOT NULL,
      sig TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  @override
  Future<void> create(Database db) async {
    // Create both tables (IF NOT EXISTS prevents errors if they already exist)
    await db.execute(createQuery);
    await _tagTable.create(db);

    // Create indexes for common queries (IF NOT EXISTS prevents errors)
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_events_pubkey ON $name(pubkey)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_events_kind ON $name(kind)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_events_created_at ON $name(created_at)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Insert or replace a nostr event (tags are automatically stored)
  Future<void> insert(NostrEventModel event) async {
    await db.insert(name, {
      'id': event.id,
      'pubkey': event.pubkey,
      'kind': event.kind,
      'content': event.content,
      'sig': event.sig,
      'created_at': event.createdAt.millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Tags are automatically stored
    await _tagTable.insertTags(event.id, event.tags);
  }

  /// Insert multiple events in a batch (tags are automatically stored)
  Future<void> insertAll(List<NostrEventModel> events) async {
    final batch = db.batch();

    for (final event in events) {
      batch.insert(name, {
        'id': event.id,
        'pubkey': event.pubkey,
        'kind': event.kind,
        'content': event.content,
        'sig': event.sig,
        'created_at': event.createdAt.millisecondsSinceEpoch ~/ 1000,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);

    // Insert tags for all events
    for (final event in events) {
      await _tagTable.insertTags(event.id, event.tags);
    }
  }

  /// Get an event by id (tags are automatically loaded)
  Future<NostrEventModel?> getById(String id) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;

    final eventMap = maps.first;
    final tags = await _tagTable.getTags(id);

    return NostrEventModel(
      id: eventMap['id'],
      pubkey: eventMap['pubkey'],
      kind: eventMap['kind'],
      content: eventMap['content'],
      tags: tags,
      sig: eventMap['sig'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (eventMap['created_at'] as int) * 1000,
      ),
    );
  }

  /// Query events with optional filters (tags are automatically loaded)
  ///
  /// Examples:
  /// - `query(pubkey: 'abc123')` - Get all events from a pubkey
  /// - `query(kind: 1)` - Get all kind 1 events
  /// - `query(tagKey: 'p', tagValue: 'pubkey123')` - Get events with specific tag
  /// - `query(pubkey: 'abc', kind: 1, limit: 10)` - Combine filters
  Future<List<NostrEventModel>> query({
    String? pubkey,
    int? kind,
    int? limit,
    int? offset,
    String? tagKey,
    String? tagValue,
  }) async {
    String whereClause = '1=1';
    List<dynamic> whereArgs = [];

    if (pubkey != null) {
      whereClause += ' AND pubkey = ?';
      whereArgs.add(pubkey);
    }

    if (kind != null) {
      whereClause += ' AND kind = ?';
      whereArgs.add(kind);
    }

    // If filtering by tags, we need to join with the tags table
    if (tagKey != null || tagValue != null) {
      final eventIds = await _tagTable.queryEventIds(
        tagKey: tagKey,
        tagValue: tagValue,
      );

      if (eventIds.isEmpty) {
        return [];
      }

      whereClause +=
          ' AND id IN (${List.filled(eventIds.length, '?').join(',')})';
      whereArgs.addAll(eventIds);
    }

    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    final events = <NostrEventModel>[];

    for (final eventMap in maps) {
      final tags = await _tagTable.getTags(eventMap['id']);
      events.add(
        NostrEventModel(
          id: eventMap['id'],
          pubkey: eventMap['pubkey'],
          kind: eventMap['kind'],
          content: eventMap['content'],
          tags: tags,
          sig: eventMap['sig'],
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (eventMap['created_at'] as int) * 1000,
          ),
        ),
      );
    }

    return events;
  }

  /// Get events by pubkey (convenience method)
  Future<List<NostrEventModel>> getByPubkey(String pubkey, {int? limit}) async {
    return query(pubkey: pubkey, limit: limit);
  }

  /// Get events by kind (convenience method)
  Future<List<NostrEventModel>> getByKind(int kind, {int? limit}) async {
    return query(kind: kind, limit: limit);
  }

  /// Get events by tag (convenience method)
  ///
  /// Example: `getByTag('p', 'pubkey123')` - Get all events that reference pubkey123
  Future<List<NostrEventModel>> getByTag(
    String tagKey,
    String tagValue, {
    int? limit,
  }) async {
    return query(tagKey: tagKey, tagValue: tagValue, limit: limit);
  }

  /// Query events with multiple tag filters (all tags must match)
  ///
  /// This is useful for querying reactions in a specific group:
  /// ```dart
  /// // Get all kind 7 reactions in group X for post Y
  /// queryWithMultipleTags(
  ///   kind: 7,
  ///   tagFilters: {'g': groupIdHex, 'e': postId},
  /// )
  /// ```
  Future<List<NostrEventModel>> queryWithMultipleTags({
    String? pubkey,
    int? kind,
    int? limit,
    int? offset,
    required Map<String, String> tagFilters,
  }) async {
    if (tagFilters.isEmpty) {
      return query(pubkey: pubkey, kind: kind, limit: limit, offset: offset);
    }

    // Get event IDs that match ALL tag filters
    Set<String>? matchingEventIds;

    for (final entry in tagFilters.entries) {
      final eventIds = await _tagTable.queryEventIds(
        tagKey: entry.key,
        tagValue: entry.value,
      );

      if (matchingEventIds == null) {
        matchingEventIds = eventIds.toSet();
      } else {
        // Intersect to keep only events that match all filters
        matchingEventIds = matchingEventIds.intersection(eventIds.toSet());
      }

      // Early exit if no matches
      if (matchingEventIds.isEmpty) {
        return [];
      }
    }

    if (matchingEventIds == null || matchingEventIds.isEmpty) {
      return [];
    }

    // Now query the events table with the filtered IDs
    String whereClause = '1=1';
    List<dynamic> whereArgs = [];

    if (pubkey != null) {
      whereClause += ' AND pubkey = ?';
      whereArgs.add(pubkey);
    }

    if (kind != null) {
      whereClause += ' AND kind = ?';
      whereArgs.add(kind);
    }

    whereClause +=
        ' AND id IN (${List.filled(matchingEventIds.length, '?').join(',')})';
    whereArgs.addAll(matchingEventIds);

    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    final events = <NostrEventModel>[];

    for (final eventMap in maps) {
      final tags = await _tagTable.getTags(eventMap['id']);
      events.add(
        NostrEventModel(
          id: eventMap['id'],
          pubkey: eventMap['pubkey'],
          kind: eventMap['kind'],
          content: eventMap['content'],
          tags: tags,
          sig: eventMap['sig'],
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (eventMap['created_at'] as int) * 1000,
          ),
        ),
      );
    }

    return events;
  }

  /// Delete an event by id (tags are automatically deleted)
  Future<void> delete(String id) async {
    await _tagTable.deleteTags(id);
    await db.delete(name, where: 'id = ?', whereArgs: [id]);
  }

  /// Delete multiple events by ids (tags are automatically deleted)
  Future<void> deleteAll(List<String> ids) async {
    if (ids.isEmpty) return;

    for (final id in ids) {
      await _tagTable.deleteTags(id);
    }

    await db.delete(
      name,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  /// Clear all events (tags are automatically cleared)
  Future<void> clear() async {
    await _tagTable.clear();
    await db.delete(name);
  }
}

/// Internal tag table - not meant for direct use
/// Use NostrEventTable instead, which handles tags automatically
class _NostrEventTagTable extends DBTable {
  _NostrEventTagTable(super.db);

  @override
  String get name => 'nostr_event_tags';

  @override
  String get createQuery =>
      '''
    CREATE TABLE IF NOT EXISTS $name (
      event_id TEXT NOT NULL,
      tag_index INTEGER NOT NULL,
      tag_key TEXT NOT NULL,
      tag_values TEXT NOT NULL,
      PRIMARY KEY (event_id, tag_index),
      FOREIGN KEY (event_id) REFERENCES nostr_events(id) ON DELETE CASCADE
    )
  ''';

  @override
  Future<void> create(Database db) async {
    // Create table (IF NOT EXISTS prevents errors if it already exists)
    await db.execute(createQuery);

    // Create indexes for efficient tag queries (IF NOT EXISTS prevents errors)
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_event_tags_event_id ON $name(event_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_event_tags_key ON $name(tag_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nostr_event_tags_key_value ON $name(tag_key, tag_values)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Insert tags for an event (internal use only)
  Future<void> insertTags(String eventId, List<List<String>> tags) async {
    // Delete existing tags first
    await deleteTags(eventId);

    for (int i = 0; i < tags.length; i++) {
      final tag = tags[i];
      if (tag.isEmpty) continue;

      final tagKey = tag[0];
      final tagValues = tag.length > 1 ? tag.sublist(1) : <String>[];

      await db.insert(name, {
        'event_id': eventId,
        'tag_index': i,
        'tag_key': tagKey,
        'tag_values': jsonEncode(tagValues),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Get all tags for an event (internal use only)
  Future<List<List<String>>> getTags(String eventId) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'event_id = ?',
      whereArgs: [eventId],
      orderBy: 'tag_index ASC',
    );

    return maps.map((map) {
      final tagKey = map['tag_key'] as String;
      final tagValuesJson = map['tag_values'] as String;
      final tagValues = jsonDecode(tagValuesJson) as List<dynamic>;

      return [tagKey, ...tagValues.map((v) => v.toString())];
    }).toList();
  }

  /// Query event IDs by tag key and/or value (internal use only)
  Future<List<String>> queryEventIds({String? tagKey, String? tagValue}) async {
    String whereClause = '1=1';
    List<dynamic> whereArgs = [];

    if (tagKey != null) {
      whereClause += ' AND tag_key = ?';
      whereArgs.add(tagKey);
    }

    final List<Map<String, dynamic>> maps = await db.query(
      name,
      columns: ['event_id', 'tag_values'],
      where: whereClause,
      whereArgs: whereArgs,
    );

    // Filter by tagValue if specified
    if (tagValue != null) {
      final filteredMaps = maps.where((map) {
        final tagValuesJson = map['tag_values'] as String;
        try {
          final tagValues = jsonDecode(tagValuesJson) as List<dynamic>;
          return tagValues.any((v) => v.toString() == tagValue);
        } catch (e) {
          return false;
        }
      }).toList();

      return filteredMaps
          .map((map) => map['event_id'] as String)
          .toSet()
          .toList();
    }

    return maps.map((map) => map['event_id'] as String).toSet().toList();
  }

  /// Delete all tags for an event (internal use only)
  Future<void> deleteTags(String eventId) async {
    await db.delete(name, where: 'event_id = ?', whereArgs: [eventId]);
  }

  /// Clear all tags (internal use only)
  Future<void> clear() async {
    await db.delete(name);
  }
}
