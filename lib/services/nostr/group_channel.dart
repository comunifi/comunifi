import 'dart:convert';

import 'package:comunifi/models/nostr_event.dart';

/// Metadata for a NIP-28 channel within a NIP-29 group
/// This represents the relay-generated per-channel metadata (kind 39004)
/// as described in docs/group_channels.md
class GroupChannelMetadata {
  /// Channel ID (from the kind 40 event that created it)
  final String id;

  /// NIP-29 group ID (hex)
  final String groupId;

  /// Channel name (e.g., "general", "support")
  final String name;

  /// Optional channel description
  final String? about;

  /// Optional channel picture URL
  final String? picture;

  /// Suggested relay URLs for this channel (per NIP-28)
  final List<String> relays;

  /// Pubkey of the channel creator (from kind 40)
  final String creator;

  /// Optional extra metadata (app-specific extensions)
  final Map<String, dynamic>? extra;

  /// Timestamp when the metadata was last updated
  final DateTime createdAt;

  GroupChannelMetadata({
    required this.id,
    required this.groupId,
    required this.name,
    this.about,
    this.picture,
    required this.relays,
    required this.creator,
    this.extra,
    required this.createdAt,
  });

  /// Parse a kind 39004 event into GroupChannelMetadata
  /// The event should have:
  /// - Tags: ['h', groupId], ['d', 'group_id:channel_id'], ['e', channelId]
  /// - Content: JSON with id, group_id, name, about, picture, relays, creator, extra
  factory GroupChannelMetadata.fromNostrEvent(NostrEventModel event) {
    if (event.kind != kindGroupChannelMetadata) {
      throw ArgumentError(
        'Expected kind 39004 (GroupChannelMetadata), got ${event.kind}',
      );
    }

    // Parse JSON content
    Map<String, dynamic> contentJson;
    try {
      contentJson = jsonDecode(event.content) as Map<String, dynamic>;
    } catch (e) {
      throw FormatException('Invalid JSON in channel metadata content: $e');
    }

    // Extract group ID from 'h' tag or JSON
    String? groupId;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'h' && tag.length > 1) {
        groupId = tag[1];
        break;
      }
    }
    groupId ??= contentJson['group_id'] as String?;

    // Extract channel ID from JSON or 'e' tag
    String? channelId = contentJson['id'] as String?;
    if (channelId == null) {
      for (final tag in event.tags) {
        if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
          channelId = tag[1];
          break;
        }
      }
    }
    // Fallback to event ID if still not found
    channelId ??= event.id;

    if (groupId == null) {
      throw FormatException('Missing group_id in channel metadata');
    }

    // Parse relays (can be array or null)
    List<String> relays = [];
    if (contentJson['relays'] != null) {
      final relaysList = contentJson['relays'];
      if (relaysList is List) {
        relays = relaysList.map((r) => r.toString()).toList();
      }
    }

    // Parse extra metadata
    Map<String, dynamic>? extra;
    if (contentJson['extra'] != null) {
      extra = Map<String, dynamic>.from(contentJson['extra'] as Map);
    }

    return GroupChannelMetadata(
      id: channelId,
      groupId: groupId,
      name: contentJson['name'] as String? ?? '',
      about: contentJson['about'] as String?,
      picture: contentJson['picture'] as String?,
      relays: relays,
      creator: contentJson['creator'] as String? ?? event.pubkey,
      extra: extra,
      createdAt: event.createdAt,
    );
  }

  /// Convert to JSON (for serialization/caching)
  Map<String, dynamic> toJson() => {
        'id': id,
        'group_id': groupId,
        'name': name,
        'about': about,
        'picture': picture,
        'relays': relays,
        'creator': creator,
        'extra': extra,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  /// Create from JSON (for deserialization/caching)
  factory GroupChannelMetadata.fromJson(Map<String, dynamic> json) {
    return GroupChannelMetadata(
      id: json['id'] as String,
      groupId: json['group_id'] as String,
      name: json['name'] as String,
      about: json['about'] as String?,
      picture: json['picture'] as String?,
      relays: (json['relays'] as List<dynamic>?)
              ?.map((r) => r.toString())
              .toList() ??
          [],
      creator: json['creator'] as String,
      extra: json['extra'] != null
          ? Map<String, dynamic>.from(json['extra'] as Map)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['created_at'] as int) * 1000,
      ),
    );
  }

  @override
  String toString() => 'GroupChannelMetadata(id: $id, groupId: $groupId, name: $name)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupChannelMetadata &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          groupId == other.groupId;

  @override
  int get hashCode => id.hashCode ^ groupId.hashCode;
}
