import 'dart:typed_data';
import 'dart:math';
import 'crypto/crypto.dart' as mls_crypto;
import 'group_state/group_state.dart';
import 'key_schedule/key_schedule.dart';
import 'ratchet_tree/ratchet_tree.dart';
import 'storage/storage.dart';
import 'mls_group.dart';

/// MLS Service - main entry point for MLS operations
class MlsService {
  final mls_crypto.MlsCryptoProvider cryptoProvider;
  final MlsStorage storage;

  MlsService({required this.cryptoProvider, required this.storage});

  /// Create a new MLS group
  Future<MlsGroup> createGroup({
    required String creatorUserId,
    required String groupName,
  }) async {
    // Generate identity key pair
    final identityKeyPair = await cryptoProvider.signatureScheme
        .generateKeyPair();

    // Generate leaf HPKE key pair
    final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

    // Create initial ratchet tree with single leaf
    final initialLeaf = RatchetNode.withKeys(
      hpkeKeyPair.publicKey,
      hpkeKeyPair.privateKey,
      null, // Secret will be derived
    );
    final tree = RatchetTree([initialLeaf]);

    // Create group ID
    final groupIdBytes = Uint8List(16);
    final random = Random.secure();
    for (int i = 0; i < groupIdBytes.length; i++) {
      groupIdBytes[i] = random.nextInt(256);
    }
    final groupId = GroupId(groupIdBytes);

    // Compute initial tree hash (simplified - in production would hash the tree)
    final treeHash = Uint8List(32);
    for (int i = 0; i < treeHash.length; i++) {
      treeHash[i] = random.nextInt(256);
    }

    // Initial confirmed transcript hash
    final confirmedTranscriptHash = Uint8List(32);
    for (int i = 0; i < confirmedTranscriptHash.length; i++) {
      confirmedTranscriptHash[i] = random.nextInt(256);
    }

    // Create initial group context
    final context = GroupContext(
      groupId: groupId,
      epoch: 0,
      treeHash: treeHash,
      confirmedTranscriptHash: confirmedTranscriptHash,
    );

    // Derive initial epoch secrets
    // In production, init_secret would come from group creation protocol
    final initSecret = Uint8List(32);
    for (int i = 0; i < initSecret.length; i++) {
      initSecret[i] = random.nextInt(256);
    }

    final keySchedule = KeySchedule(cryptoProvider.kdf);
    final groupContextHash = Uint8List(32); // Simplified - would hash context
    final secrets = await keySchedule.deriveEpochSecrets(
      initSecret: initSecret,
      groupContextHash: groupContextHash,
    );

    // Create initial member (creator is at leaf index 0)
    final localLeafIndex = LeafIndex(0);
    final member = GroupMember(
      userId: creatorUserId,
      leafIndex: localLeafIndex,
      identityKey: identityKeyPair.publicKey,
      hpkePublicKey: hpkeKeyPair.publicKey,
    );

    // Create group state with creator's leaf index
    final state = GroupState(
      context: context,
      tree: tree,
      members: {localLeafIndex: member},
      secrets: secrets,
      identityPrivateKey: identityKeyPair.privateKey,
      leafHpkePrivateKey: hpkeKeyPair.privateKey,
      localLeafIndex: localLeafIndex,
    );

    // Save state and group name
    await storage.saveGroupState(state);
    await storage.saveGroupName(groupId, groupName);

    // Create and return group
    return MlsGroup(groupId, groupName, state, cryptoProvider, storage);
  }

  /// Load an existing group
  Future<MlsGroup?> loadGroup(GroupId groupId) async {
    final state = await storage.loadGroupState(groupId);
    if (state == null) return null;

    // Load group name from storage
    final groupName = await storage.loadGroupName(groupId);
    if (groupName == null) {
      // Fallback to default name if not found
      return MlsGroup(groupId, 'Unnamed Group', state, cryptoProvider, storage);
    }

    return MlsGroup(groupId, groupName, state, cryptoProvider, storage);
  }
}
