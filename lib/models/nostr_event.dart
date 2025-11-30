import 'package:dart_nostr/dart_nostr.dart';

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
