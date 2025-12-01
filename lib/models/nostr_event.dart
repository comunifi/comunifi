import 'dart:convert';

import 'package:dart_nostr/dart_nostr.dart';

/// Kind 40: Channel/Group announcement
const int kindGroupAnnouncement = 40;

/// Kind 1059: Encrypted envelope containing an encrypted Nostr event
const int kindEncryptedEnvelope = 1059;

/// Kind 1060: MLS Welcome message (encrypted invitation to join a group)
const int kindMlsWelcome = 1060;

class NostrEventModel {
  final String id;
  final String pubkey;
  final int kind;
  final String content;
  final List<List<String>> tags;
  final String sig;

  final DateTime createdAt;

  const NostrEventModel({
    required this.id,
    required this.pubkey,
    required this.kind,
    required this.content,
    required this.tags,
    required this.sig,
    required this.createdAt,
  });

  factory NostrEventModel.fromPartialData({
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    NostrKeyPairs? keyPairs,
    DateTime? createdAt,
  }) {
    return NostrEventModel(
      id: '',
      pubkey: keyPairs?.public ?? '',
      kind: kind,
      content: content,
      tags: tags,
      sig: '',
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  factory NostrEventModel.fromJson(Map<String, dynamic> json) {
    return NostrEventModel(
      id: json['id'],
      pubkey: json['pubkey'],
      kind: json['kind'],
      content: json['content'],
      tags: _tagsFromJson(json['tags']),
      sig: json['sig'],
      createdAt: _createdAtFromJson(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'kind': kind,
    'content': content,
    'tags': _tagsToJson(tags),
    'sig': sig,
    'created_at': _createdAtToJson(createdAt),
  };

  static List<List<String>> _tagsFromJson(dynamic json) {
    if (json == null) return [];
    return (json as List).map((tag) {
      if (tag is List) {
        return tag.map((item) => item.toString()).toList();
      }
      return [tag.toString()];
    }).toList();
  }

  static dynamic _tagsToJson(List<List<String>> value) {
    return value.map((e) => e.map((e) => e).toList()).toList();
  }

  static DateTime _createdAtFromJson(dynamic json) {
    if (json is int) {
      return DateTime.fromMillisecondsSinceEpoch(json * 1000);
    }
    return DateTime.now();
  }

  static dynamic _createdAtToJson(DateTime value) {
    return value.millisecondsSinceEpoch ~/ 1000;
  }

  /// Check if this event is an encrypted envelope (kind 1059)
  bool get isEncryptedEnvelope => kind == kindEncryptedEnvelope;

  /// Get the recipient public key from an encrypted envelope
  /// Returns null if this is not an encrypted envelope or if no 'p' tag is found
  String? get encryptedEnvelopeRecipient {
    if (!isEncryptedEnvelope) return null;

    // Find the 'p' tag which contains the recipient's public key
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Get the MLS group ID from an encrypted envelope
  /// Returns null if this is not an encrypted envelope or if no 'g' tag is found
  /// The group ID is returned as a hex-encoded string
  String? get encryptedEnvelopeMlsGroupId {
    if (!isEncryptedEnvelope) return null;

    // Find the 'g' tag which contains the MLS group ID (hex-encoded)
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Create an encrypted envelope (kind 1059) from encrypted content
  ///
  /// [encryptedContent] - The encrypted JSON string of the actual Nostr event
  /// [recipientPubkey] - The public key of the recipient (will be added as 'p' tag)
  /// [mlsGroupId] - The MLS group ID as a hex-encoded string (will be added as 'g' tag)
  /// [keyPairs] - Optional key pairs for signing (if null, event will be unsigned)
  /// [createdAt] - Optional creation timestamp (defaults to now)
  ///
  /// Note: The actual encryption should be done in the service layer before calling this.
  factory NostrEventModel.createEncryptedEnvelope({
    required String encryptedContent,
    required String recipientPubkey,
    required String mlsGroupId,
    NostrKeyPairs? keyPairs,
    DateTime? createdAt,
  }) {
    // Add recipient pubkey as 'p' tag and MLS group ID as 'g' tag
    final tags = [
      ['p', recipientPubkey],
      ['g', mlsGroupId],
      ...addClientIdTag([]),
    ];

    return NostrEventModel(
      id: '',
      pubkey: keyPairs?.public ?? '',
      kind: kindEncryptedEnvelope,
      content: encryptedContent,
      tags: tags,
      sig: '',
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Get the encrypted content from an encrypted envelope
  ///
  /// Returns the encrypted content string if this is an encrypted envelope,
  /// otherwise returns null.
  ///
  /// Note: Decryption should be done in the service layer after extracting this content.
  String? getEncryptedContent() {
    if (!isEncryptedEnvelope) return null;
    return content;
  }

  /// Convert this normal Nostr event into an encrypted envelope (kind 1059)
  ///
  /// [encryptedContent] - The encrypted JSON string of this event
  /// [recipientPubkey] - The public key of the recipient (will be added as 'p' tag)
  /// [mlsGroupId] - The MLS group ID as a hex-encoded string (will be added as 'g' tag)
  /// [keyPairs] - Optional key pairs for signing the envelope (if null, envelope will be unsigned)
  /// [createdAt] - Optional creation timestamp for the envelope (defaults to now)
  ///
  /// Returns a new [NostrEventModel] of kind 1059 (encrypted envelope) containing
  /// the encrypted version of this event.
  ///
  /// Note: The actual encryption should be done in the service layer before calling this.
  /// This method serializes this event to JSON, which should then be encrypted externally.
  ///
  /// Example:
  /// ```dart
  /// final normalEvent = NostrEventModel.fromPartialData(...);
  /// final eventJson = jsonEncode(normalEvent.toJson());
  /// final encryptedContent = await encryptionService.encrypt(eventJson);
  /// final envelope = normalEvent.toEncryptedEnvelope(
  ///   encryptedContent: encryptedContent,
  ///   recipientPubkey: recipientPubkey,
  ///   mlsGroupId: groupIdHex,
  ///   keyPairs: keyPairs,
  /// );
  /// ```
  NostrEventModel toEncryptedEnvelope({
    required String encryptedContent,
    required String recipientPubkey,
    required String mlsGroupId,
    NostrKeyPairs? keyPairs,
    DateTime? createdAt,
  }) {
    if (isEncryptedEnvelope) {
      throw Exception(
        'Cannot convert: this event is already an encrypted envelope',
      );
    }

    // Add recipient pubkey as 'p' tag and MLS group ID as 'g' tag
    final tags = [
      ['p', recipientPubkey],
      ['g', mlsGroupId],
      ...addClientIdTag([]),
    ];

    return NostrEventModel(
      id: '',
      pubkey: keyPairs?.public ?? '',
      kind: kindEncryptedEnvelope,
      content: encryptedContent,
      tags: tags,
      sig: '',
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Decrypt a Nostr event from an encrypted envelope
  ///
  /// [decryptedContent] - The decrypted JSON string of the Nostr event
  ///
  /// Returns a [NostrEventModel] parsed from the decrypted content.
  ///
  /// Throws an exception if the decrypted content is not valid JSON or
  /// cannot be parsed as a Nostr event.
  ///
  /// Example:
  /// ```dart
  /// final encryptedEnvelope = NostrEventModel.fromJson(envelopeJson);
  /// final encryptedContent = encryptedEnvelope.getEncryptedContent();
  /// final decryptedContent = await decryptFunction(encryptedContent);
  /// final decryptedEvent = encryptedEnvelope.decryptEvent(decryptedContent);
  /// ```
  NostrEventModel decryptEvent(String decryptedContent) {
    if (!isEncryptedEnvelope) {
      throw Exception('Cannot decrypt: this is not an encrypted envelope');
    }

    // Parse the decrypted JSON string
    final Map<String, dynamic> eventJson = Map<String, dynamic>.from(
      jsonDecode(decryptedContent),
    );

    // Create and return the decrypted event
    return NostrEventModel.fromJson(eventJson);
  }

  @override
  String toString() {
    return 'NostrEventModel(id: $id, pubkey: $pubkey, kind: $kind, content: $content, createdAt: $createdAt)';
  }
}

List<List<String>> addClientIdTag(List<List<String>> tags) {
  if (tags.any((tag) => tag[0] == 'client' && tag[1] == 'comunifi')) {
    return tags;
  }

  return [
    ['client', 'comunifi'],
    ...tags,
  ];
}
