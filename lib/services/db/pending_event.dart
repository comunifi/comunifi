import 'dart:convert';
import 'package:comunifi/services/db/db.dart';
import 'package:sqflite_common/sqflite.dart';

/// Pending event status
enum PendingEventStatus {
  pending,
  sending,
  failed,
}

/// A queued event waiting to be published to the relay
class PendingEvent {
  final String id;
  final Map<String, dynamic> eventJson;
  final String? mlsGroupId;
  final String? recipientPubkey;
  final DateTime createdAt;
  final PendingEventStatus status;
  final int retryCount;

  PendingEvent({
    required this.id,
    required this.eventJson,
    this.mlsGroupId,
    this.recipientPubkey,
    required this.createdAt,
    this.status = PendingEventStatus.pending,
    this.retryCount = 0,
  });

  PendingEvent copyWith({
    PendingEventStatus? status,
    int? retryCount,
  }) {
    return PendingEvent(
      id: id,
      eventJson: eventJson,
      mlsGroupId: mlsGroupId,
      recipientPubkey: recipientPubkey,
      createdAt: createdAt,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'event_json': jsonEncode(eventJson),
      'mls_group_id': mlsGroupId,
      'recipient_pubkey': recipientPubkey,
      'created_at': createdAt.millisecondsSinceEpoch,
      'status': status.index,
      'retry_count': retryCount,
    };
  }

  factory PendingEvent.fromMap(Map<String, dynamic> map) {
    return PendingEvent(
      id: map['id'] as String,
      eventJson: jsonDecode(map['event_json'] as String) as Map<String, dynamic>,
      mlsGroupId: map['mls_group_id'] as String?,
      recipientPubkey: map['recipient_pubkey'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      status: PendingEventStatus.values[map['status'] as int],
      retryCount: map['retry_count'] as int,
    );
  }
}

/// Table for storing pending events that haven't been published to the relay yet.
/// Acts as a queue that processes events when connection is re-established.
class PendingEventTable extends DBTable {
  PendingEventTable(super.db);

  @override
  String get name => 'pending_events';

  @override
  String get createQuery => '''
    CREATE TABLE IF NOT EXISTS $name (
      id TEXT PRIMARY KEY,
      event_json TEXT NOT NULL,
      mls_group_id TEXT,
      recipient_pubkey TEXT,
      created_at INTEGER NOT NULL,
      status INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);

    // Index for querying by status (to find pending items)
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_events_status ON $name(status)',
    );

    // Index for ordering by creation time
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_pending_events_created_at ON $name(created_at)',
    );
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here if needed
  }

  /// Add an event to the pending queue
  Future<void> enqueue(PendingEvent event) async {
    await db.insert(
      name,
      event.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get the next pending event to process (FIFO order)
  Future<PendingEvent?> peek() async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'status = ?',
      whereArgs: [PendingEventStatus.pending.index],
      orderBy: 'created_at ASC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return PendingEvent.fromMap(maps.first);
  }

  /// Get all pending events in order
  Future<List<PendingEvent>> getAllPending() async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'status = ?',
      whereArgs: [PendingEventStatus.pending.index],
      orderBy: 'created_at ASC',
    );

    return maps.map((m) => PendingEvent.fromMap(m)).toList();
  }

  /// Get count of pending events
  Future<int> getPendingCount() async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $name WHERE status = ?',
      [PendingEventStatus.pending.index],
    );
    return result.first['count'] as int;
  }

  /// Update event status
  Future<void> updateStatus(String id, PendingEventStatus status) async {
    await db.update(
      name,
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Increment retry count and optionally update status
  Future<void> incrementRetry(String id, {PendingEventStatus? status}) async {
    final event = await getById(id);
    if (event == null) return;

    await db.update(
      name,
      {
        'retry_count': event.retryCount + 1,
        if (status != null) 'status': status.index,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get event by ID
  Future<PendingEvent?> getById(String id) async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return PendingEvent.fromMap(maps.first);
  }

  /// Remove an event from the queue (after successful publish)
  Future<void> remove(String id) async {
    await db.delete(name, where: 'id = ?', whereArgs: [id]);
  }

  /// Reset all "sending" events back to "pending" (for app restart recovery)
  Future<void> resetSendingToPending() async {
    await db.update(
      name,
      {'status': PendingEventStatus.pending.index},
      where: 'status = ?',
      whereArgs: [PendingEventStatus.sending.index],
    );
  }

  /// Remove events that have exceeded max retries
  Future<int> removeFailedEvents({int maxRetries = 5}) async {
    return await db.delete(
      name,
      where: 'retry_count >= ?',
      whereArgs: [maxRetries],
    );
  }

  /// Clear all pending events
  Future<void> clear() async {
    await db.delete(name);
  }
}

