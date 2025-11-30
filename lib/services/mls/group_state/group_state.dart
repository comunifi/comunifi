import 'dart:typed_data';
import '../key_schedule/key_schedule.dart';
import '../crypto/crypto.dart' as mls_crypto;
import '../crypto/default_crypto.dart';
import '../ratchet_tree/ratchet_tree.dart';

/// Group identifier
class GroupId {
  final Uint8List bytes;

  GroupId(this.bytes);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupId && runtimeType == other.runtimeType && bytes.toString() == other.bytes.toString();

  @override
  int get hashCode => bytes.toString().hashCode;
}

/// MLS group context
class GroupContext {
  final GroupId groupId;
  final int epoch;
  final Uint8List treeHash;
  final Uint8List confirmedTranscriptHash;
  final Uint8List? extensionsHash;

  GroupContext({
    required this.groupId,
    required this.epoch,
    required this.treeHash,
    required this.confirmedTranscriptHash,
    this.extensionsHash,
  });

  /// Serialize group context
  Uint8List serialize() {
    // Simplified serialization: group_id (4 bytes length + bytes) + epoch (4 bytes) + hashes
    final groupIdLength = groupId.bytes.length;
    final totalLength = 4 + groupIdLength + 4 + treeHash.length + confirmedTranscriptHash.length + (extensionsHash?.length ?? 0);
    
    final result = Uint8List(totalLength);
    int offset = 0;
    
    // Group ID length and bytes
    result[offset++] = (groupIdLength >> 24) & 0xFF;
    result[offset++] = (groupIdLength >> 16) & 0xFF;
    result[offset++] = (groupIdLength >> 8) & 0xFF;
    result[offset++] = groupIdLength & 0xFF;
    result.setRange(offset, offset + groupIdLength, groupId.bytes);
    offset += groupIdLength;
    
    // Epoch
    result[offset++] = (epoch >> 24) & 0xFF;
    result[offset++] = (epoch >> 16) & 0xFF;
    result[offset++] = (epoch >> 8) & 0xFF;
    result[offset++] = epoch & 0xFF;
    
    // Tree hash
    result.setRange(offset, offset + treeHash.length, treeHash);
    offset += treeHash.length;
    
    // Confirmed transcript hash
    result.setRange(offset, offset + confirmedTranscriptHash.length, confirmedTranscriptHash);
    offset += confirmedTranscriptHash.length;
    
    // Extensions hash (if present)
    if (extensionsHash != null) {
      result.setRange(offset, offset + extensionsHash!.length, extensionsHash!);
    }
    
    return result;
  }

  /// Deserialize group context from bytes
  static GroupContext deserialize(Uint8List data) {
    int offset = 0;

    // Read group ID
    final groupIdLength = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    final groupIdBytes = data.sublist(offset, offset + groupIdLength);
    offset += groupIdLength;
    final groupId = GroupId(groupIdBytes);

    // Read epoch
    final epoch = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;

    // Read tree hash (assuming 32 bytes)
    final treeHash = data.sublist(offset, offset + 32);
    offset += 32;

    // Read confirmed transcript hash (assuming 32 bytes)
    final confirmedTranscriptHash = data.sublist(offset, offset + 32);
    offset += 32;

    // Read extensions hash (if present, assuming 32 bytes)
    Uint8List? extensionsHash;
    if (offset < data.length) {
      extensionsHash = data.sublist(offset, offset + 32);
    }

    return GroupContext(
      groupId: groupId,
      epoch: epoch,
      treeHash: treeHash,
      confirmedTranscriptHash: confirmedTranscriptHash,
      extensionsHash: extensionsHash,
    );
  }
}

/// Group member information
class GroupMember {
  final String userId;
  final LeafIndex leafIndex;
  final mls_crypto.PublicKey identityKey;
  final mls_crypto.PublicKey hpkePublicKey;

  GroupMember({
    required this.userId,
    required this.leafIndex,
    required this.identityKey,
    required this.hpkePublicKey,
  });
}

/// MLS group state
class GroupState {
  final GroupContext context;
  final RatchetTree tree;
  final Map<LeafIndex, GroupMember> members;
  final EpochSecrets secrets;
  final mls_crypto.PrivateKey? identityPrivateKey;
  final mls_crypto.PrivateKey? leafHpkePrivateKey;

  GroupState({
    required this.context,
    required this.tree,
    required this.members,
    required this.secrets,
    required this.identityPrivateKey,
    required this.leafHpkePrivateKey,
  });

  GroupState copyWith({
    GroupContext? context,
    RatchetTree? tree,
    Map<LeafIndex, GroupMember>? members,
    EpochSecrets? secrets,
    mls_crypto.PrivateKey? identityPrivateKey,
    mls_crypto.PrivateKey? leafHpkePrivateKey,
  }) {
    return GroupState(
      context: context ?? this.context,
      tree: tree ?? this.tree,
      members: members ?? this.members,
      secrets: secrets ?? this.secrets,
      identityPrivateKey: identityPrivateKey ?? this.identityPrivateKey,
      leafHpkePrivateKey: leafHpkePrivateKey ?? this.leafHpkePrivateKey,
    );
  }

  /// Serialize group state to bytes
  Uint8List serialize() {
    // Format: group_context + ratchet_tree + members + epoch_secrets + identity_private_key + leaf_hpke_private_key
    final contextBytes = context.serialize();
    final treeBytes = tree.serialize();
    final membersBytes = _serializeMembers(members);
    final secretsBytes = secrets.serialize();
    
    final identityPrivateKeyBytes = identityPrivateKey?.bytes;
    final leafHpkePrivateKeyBytes = leafHpkePrivateKey?.bytes;

    final totalLength = 4 + contextBytes.length +
        4 + treeBytes.length +
        4 + membersBytes.length +
        4 + secretsBytes.length +
        4 + (identityPrivateKeyBytes?.length ?? 0) +
        4 + (leafHpkePrivateKeyBytes?.length ?? 0);

    final result = Uint8List(totalLength);
    int offset = 0;

    // Write group context
    _writeUint8List(result, offset, contextBytes);
    offset += 4 + contextBytes.length;

    // Write ratchet tree
    _writeUint8List(result, offset, treeBytes);
    offset += 4 + treeBytes.length;

    // Write members
    _writeUint8List(result, offset, membersBytes);
    offset += 4 + membersBytes.length;

    // Write epoch secrets
    _writeUint8List(result, offset, secretsBytes);
    offset += 4 + secretsBytes.length;

    // Write identity private key
    if (identityPrivateKeyBytes != null) {
      _writeUint8List(result, offset, identityPrivateKeyBytes);
      offset += 4 + identityPrivateKeyBytes.length;
    } else {
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
    }

    // Write leaf HPKE private key
    if (leafHpkePrivateKeyBytes != null) {
      _writeUint8List(result, offset, leafHpkePrivateKeyBytes);
    } else {
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
    }

    return result;
  }

  void _writeUint8List(Uint8List result, int offset, Uint8List data) {
    final length = data.length;
    result[offset++] = (length >> 24) & 0xFF;
    result[offset++] = (length >> 16) & 0xFF;
    result[offset++] = (length >> 8) & 0xFF;
    result[offset++] = length & 0xFF;
    result.setRange(offset, offset + length, data);
  }

  Uint8List _serializeMembers(Map<LeafIndex, GroupMember> members) {
    // Format: member_count (4 bytes) + [members...]
    // Each member: leaf_index (4 bytes) + user_id_length (4 bytes) + user_id + identity_key_length (4 bytes) + identity_key + hpke_key_length (4 bytes) + hpke_key
    final memberCount = members.length;
    final memberData = <Uint8List>[];
    int totalLength = 4; // member_count

    for (final entry in members.entries) {
      final member = entry.value;
      final userIdBytes = Uint8List.fromList(member.userId.codeUnits);
      final identityKeyBytes = member.identityKey.bytes;
      final hpkeKeyBytes = member.hpkePublicKey.bytes;

      final memberLength = 4 + // leaf_index
          4 + userIdBytes.length + // user_id
          4 + identityKeyBytes.length + // identity_key
          4 + hpkeKeyBytes.length; // hpke_key

      final memberBytes = Uint8List(memberLength);
      int memberOffset = 0;

      // Write leaf index
      memberBytes[memberOffset++] = (entry.key.value >> 24) & 0xFF;
      memberBytes[memberOffset++] = (entry.key.value >> 16) & 0xFF;
      memberBytes[memberOffset++] = (entry.key.value >> 8) & 0xFF;
      memberBytes[memberOffset++] = entry.key.value & 0xFF;

      // Write user ID
      _writeUint8List(memberBytes, memberOffset, userIdBytes);
      memberOffset += 4 + userIdBytes.length;

      // Write identity key
      _writeUint8List(memberBytes, memberOffset, identityKeyBytes);
      memberOffset += 4 + identityKeyBytes.length;

      // Write HPKE key
      _writeUint8List(memberBytes, memberOffset, hpkeKeyBytes);

      memberData.add(memberBytes);
      totalLength += memberLength;
    }

    final result = Uint8List(totalLength);
    int offset = 0;

    // Write member count
    result[offset++] = (memberCount >> 24) & 0xFF;
    result[offset++] = (memberCount >> 16) & 0xFF;
    result[offset++] = (memberCount >> 8) & 0xFF;
    result[offset++] = memberCount & 0xFF;

    // Write members
    for (final memberBytes in memberData) {
      result.setRange(offset, offset + memberBytes.length, memberBytes);
      offset += memberBytes.length;
    }

    return result;
  }

  /// Deserialize group state from bytes
  static GroupState deserialize(
    Uint8List data,
    mls_crypto.MlsCryptoProvider cryptoProvider,
  ) {
    int offset = 0;

    // Read group context
    final contextBytes = _readUint8List(data, offset);
    offset += 4 + contextBytes.length;
    final context = GroupContext.deserialize(contextBytes);

    // Read ratchet tree
    final treeBytes = _readUint8List(data, offset);
    offset += 4 + treeBytes.length;
    final tree = RatchetTree.deserialize(treeBytes);

    // Read members
    final membersBytes = _readUint8List(data, offset);
    offset += 4 + membersBytes.length;
    final members = _deserializeMembers(membersBytes, cryptoProvider);

    // Read epoch secrets
    final secretsBytes = _readUint8List(data, offset);
    offset += 4 + secretsBytes.length;
    final secrets = EpochSecrets.deserialize(secretsBytes);

    // Read identity private key
    final identityPrivateKeyLength = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    mls_crypto.PrivateKey? identityPrivateKey;
    if (identityPrivateKeyLength > 0) {
      final identityPrivateKeyBytes = data.sublist(offset, offset + identityPrivateKeyLength);
      identityPrivateKey = DefaultPrivateKey(identityPrivateKeyBytes);
      offset += identityPrivateKeyLength;
    }

    // Read leaf HPKE private key
    final leafHpkePrivateKeyLength = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    mls_crypto.PrivateKey? leafHpkePrivateKey;
    if (leafHpkePrivateKeyLength > 0) {
      final leafHpkePrivateKeyBytes = data.sublist(offset, offset + leafHpkePrivateKeyLength);
      leafHpkePrivateKey = DefaultPrivateKey(leafHpkePrivateKeyBytes);
    }

    return GroupState(
      context: context,
      tree: tree,
      members: members,
      secrets: secrets,
      identityPrivateKey: identityPrivateKey,
      leafHpkePrivateKey: leafHpkePrivateKey,
    );
  }

  static Uint8List _readUint8List(Uint8List data, int offset) {
    final length = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    return data.sublist(offset + 4, offset + 4 + length);
  }

  static Map<LeafIndex, GroupMember> _deserializeMembers(
    Uint8List data,
    mls_crypto.MlsCryptoProvider cryptoProvider,
  ) {
    final members = <LeafIndex, GroupMember>{};
    int offset = 0;

    // Read member count
    final memberCount = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;

    for (int i = 0; i < memberCount; i++) {
      // Read leaf index
      final leafIndex = (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
      offset += 4;

      // Read user ID
      final userIdBytes = _readUint8List(data, offset);
      offset += 4 + userIdBytes.length;
      final userId = String.fromCharCodes(userIdBytes);

      // Read identity key
      final identityKeyBytes = _readUint8List(data, offset);
      offset += 4 + identityKeyBytes.length;
      final identityKey = DefaultPublicKey(identityKeyBytes);

      // Read HPKE key
      final hpkeKeyBytes = _readUint8List(data, offset);
      offset += 4 + hpkeKeyBytes.length;
      final hpkeKey = DefaultPublicKey(hpkeKeyBytes);

      members[LeafIndex(leafIndex)] = GroupMember(
        userId: userId,
        leafIndex: LeafIndex(leafIndex),
        identityKey: identityKey,
        hpkePublicKey: hpkeKey,
      );
    }

    return members;
  }
}

