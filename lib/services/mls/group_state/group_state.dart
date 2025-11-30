import 'dart:typed_data';
import '../key_schedule/key_schedule.dart';
import '../crypto/crypto.dart' as mls_crypto;
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
}

