import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'crypto/crypto.dart' as mls_crypto;
import 'crypto/crypto_isolate.dart';
import 'crypto/default_crypto.dart';
import 'group_state/group_state.dart';
import 'key_schedule/key_schedule.dart';
import 'messages/messages.dart';
import 'storage/storage.dart';
import 'ratchet_tree/ratchet_tree.dart' hide PrivateKey;

/// MLS Group - represents an MLS group with encryption/decryption capabilities
class MlsGroup {
  final GroupId id;
  final String name;

  final mls_crypto.MlsCryptoProvider _crypto;
  final MlsStorage _storage;
  GroupState _state;

  /// Internal constructor - use MlsService to create groups
  MlsGroup(this.id, this.name, this._state, this._crypto, this._storage);

  /// Get current epoch (for testing)
  int get epoch => _state.context.epoch;

  /// Get member count (for testing)
  int get memberCount => _state.members.length;

  /// Get member by user ID (for testing)
  GroupMember? getMemberByUserId(String userId) {
    try {
      return _state.members.values.firstWhere((m) => m.userId == userId);
    } catch (e) {
      return null;
    }
  }

  /// Get application secret for background crypto operations
  Uint8List get applicationSecret => _state.secrets.applicationSecret;

  /// Get sender leaf index value
  int get senderLeafIndexValue => _state.members.keys.first.value;

  /// Get expected generation for a sender
  int getExpectedGeneration(int senderIndex) {
    return _state.getGeneration(LeafIndex(senderIndex));
  }

  /// Update generation after successful decryption
  void updateGeneration(int senderIndex, int generation) {
    _state.setGeneration(LeafIndex(senderIndex), generation);
  }

  /// Increment and get generation for encryption
  int incrementAndGetGeneration() {
    final senderLeafIndex = _state.members.keys.first;
    return _state.incrementGeneration(senderLeafIndex);
  }

  /// Encrypt an application message (runs crypto in background isolate)
  Future<MlsCiphertext> encryptApplicationMessage(Uint8List plaintext) async {
    // Get sender leaf index
    final senderLeafIndex = _state.members.keys.first;

    // Get and increment generation for this sender (prevents nonce reuse)
    final generation = _state.incrementGeneration(senderLeafIndex);

    // Run encryption in background isolate to keep UI smooth
    final result = await MlsCryptoBackground.encrypt(
      plaintext: plaintext,
      applicationSecret: _state.secrets.applicationSecret,
      senderIndex: senderLeafIndex.value,
      generation: generation,
    );

    if (!result.success) {
      throw MlsError('Encryption failed: ${result.error}');
    }

    return MlsCiphertext(
      groupId: id,
      epoch: _state.context.epoch,
      senderIndex: senderLeafIndex.value,
      nonce: result.nonce!,
      ciphertext: result.ciphertext!,
      contentType: MlsContentType.application,
    );
  }

  /// Decrypt an application message (runs crypto in background isolate)
  Future<Uint8List> decryptApplicationMessage(MlsCiphertext ciphertext) async {
    // Verify group ID and epoch
    if (ciphertext.groupId.bytes.toString() != id.bytes.toString()) {
      throw MlsError('Group ID mismatch');
    }

    if (ciphertext.epoch != _state.context.epoch) {
      throw MlsError('Epoch mismatch - message from different epoch');
    }

    final senderLeafIndex = LeafIndex(ciphertext.senderIndex);

    // Get expected generation (what we think the sender should be at)
    final expectedGeneration = _state.getGeneration(senderLeafIndex);

    // Run decryption in background isolate to keep UI smooth
    final result = await MlsCryptoBackground.decrypt(
      epoch: ciphertext.epoch,
      senderIndex: ciphertext.senderIndex,
      nonce: ciphertext.nonce,
      ciphertext: ciphertext.ciphertext,
      applicationSecret: _state.secrets.applicationSecret,
      expectedGeneration: expectedGeneration,
    );

    if (!result.success) {
      throw DecryptionFailed(
        'Failed to decrypt message: ${result.error ?? "Unknown error"}',
      );
    }

    // Update our generation tracking
    if (result.usedGeneration != null) {
      _state.setGeneration(senderLeafIndex, result.usedGeneration!);
    }

    return result.plaintext!;
  }

  /// Add members to the group
  /// Returns: (commit, commit ciphertexts, welcome messages)
  Future<(Commit, List<MlsCiphertext>, List<Welcome>)> addMembers(
    List<AddProposal> adds,
  ) async {
    if (adds.isEmpty) {
      throw MlsError('Cannot add empty list of members');
    }

    // Get local member's leaf index
    final localLeafIndex = _state.members.keys.first;

    // Create new tree with added leaves
    final newTree = RatchetTree(List.from(_state.tree.nodes));
    final newMembers = Map<LeafIndex, GroupMember>.from(_state.members);

    // Add new members to tree
    final newLeafIndices = <LeafIndex>[];
    for (final add in adds) {
      final newLeafIndex = newTree.appendLeaf(
        RatchetNode.withKeys(add.hpkeInitKey, null, null),
      );
      newLeafIndices.add(newLeafIndex);

      // Create member entry
      newMembers[newLeafIndex] = GroupMember(
        userId: add.userId,
        leafIndex: newLeafIndex,
        identityKey: add.identityKey,
        hpkePublicKey: add.hpkeInitKey,
      );
    }

    // Compute update path from local leaf to root
    final updatePath = await _computeUpdatePath(localLeafIndex, newTree);

    // Advance epoch
    final newEpoch = _state.context.epoch + 1;
    final newTreeHash = await _computeTreeHash(newTree);
    final newConfirmedTranscriptHash = await _computeTranscriptHash(
      _state.context.confirmedTranscriptHash,
      updatePath,
    );

    // Derive new init secret and epoch secrets
    final random = Random.secure();
    final newInitSecret = Uint8List(32);
    for (int i = 0; i < newInitSecret.length; i++) {
      newInitSecret[i] = random.nextInt(256);
    }

    final keySchedule = KeySchedule(_crypto.kdf);
    final newGroupContext = GroupContext(
      groupId: id,
      epoch: newEpoch,
      treeHash: newTreeHash,
      confirmedTranscriptHash: newConfirmedTranscriptHash,
    );
    final groupContextHash = newGroupContext.serialize();
    final newSecrets = await keySchedule.deriveEpochSecrets(
      initSecret: newInitSecret,
      groupContextHash: groupContextHash,
    );

    // Update state
    _state = _state.copyWith(
      context: newGroupContext,
      tree: newTree,
      members: newMembers,
      secrets: newSecrets,
    );

    // Save updated state
    await _storage.saveGroupState(_state);

    // Create commit
    final commit = Commit(proposals: adds, updatePath: updatePath);

    // Encrypt commit message
    final commitPlaintext = _serializeCommit(commit);
    final commitCiphertext = await _encryptCommit(commitPlaintext, newSecrets);

    // Create Welcome messages for new members
    final welcomeMessages = <Welcome>[];
    for (int i = 0; i < adds.length; i++) {
      final add = adds[i];
      final newLeafIndex = newLeafIndices[i];
      
      // Serialize the new group state (public parts only - no private keys)
      // In production, this would be a proper GroupInfo structure
      final groupInfo = _serializeGroupInfo(newGroupContext, newTree, newMembers);
      
      // Encrypt group secrets for this new member using their HPKE public key
      // The secrets include: init_secret, epoch secrets, and tree position
      final groupSecrets = _serializeGroupSecrets(
        newInitSecret,
        newSecrets,
        newLeafIndex,
      );
      
      // Encrypt group secrets with new member's HPKE public key
      final encapResult = await _crypto.hpke.setupBaseSender(
        recipientPublicKey: add.hpkeInitKey,
        info: Uint8List.fromList(utf8.encode('mls-welcome')),
      );
      final sealedGroupSecrets = await encapResult.context.seal(
        plaintext: groupSecrets,
        aad: Uint8List(0),
      );
      
      // Prepend the HPKE enc (ephemeral public key, 32 bytes) to the sealed secrets
      // This is required for the recipient to decrypt using setupBaseRecipient
      final enc = encapResult.enc;
      final encryptedGroupSecrets = Uint8List(enc.length + sealedGroupSecrets.length);
      encryptedGroupSecrets.setRange(0, enc.length, enc);
      encryptedGroupSecrets.setRange(enc.length, encryptedGroupSecrets.length, sealedGroupSecrets);
      
      // Encrypt group info (simplified - in production would use proper encryption)
      // For now, we'll encrypt it with the same HPKE context
      final encryptedGroupInfo = await encapResult.context.seal(
        plaintext: groupInfo,
        aad: Uint8List(0),
      );
      
      final welcome = Welcome(
        groupId: id,
        encryptedGroupSecrets: encryptedGroupSecrets,
        encryptedGroupInfo: encryptedGroupInfo,
      );
      
      welcomeMessages.add(welcome);
    }

    return (commit, [commitCiphertext], welcomeMessages);
  }

  /// Remove members from the group
  Future<(Commit, List<MlsCiphertext>)> removeMembers(
    List<RemoveProposal> removes,
  ) async {
    if (removes.isEmpty) {
      throw MlsError('Cannot remove empty list of members');
    }

    // Get local member's leaf index
    final localLeafIndex = _state.members.keys.first;

    // Create new tree with removed leaves blanked
    final newTree = RatchetTree(List.from(_state.tree.nodes));
    final newMembers = Map<LeafIndex, GroupMember>.from(_state.members);

    // Remove members from tree
    for (final remove in removes) {
      final leafIndex = LeafIndex(remove.removedLeafIndex);
      if (!newMembers.containsKey(leafIndex)) {
        throw MlsError(
          'Cannot remove non-existent member at leaf ${remove.removedLeafIndex}',
        );
      }

      // Blank the subtree
      newTree.blankSubtree(leafIndex);
      newMembers.remove(leafIndex);
    }

    // Compute update path from local leaf to root
    final updatePath = await _computeUpdatePath(localLeafIndex, newTree);

    // Advance epoch
    final newEpoch = _state.context.epoch + 1;
    final newTreeHash = await _computeTreeHash(newTree);
    final newConfirmedTranscriptHash = await _computeTranscriptHash(
      _state.context.confirmedTranscriptHash,
      updatePath,
    );

    // Derive new init secret and epoch secrets
    final random = Random.secure();
    final newInitSecret = Uint8List(32);
    for (int i = 0; i < newInitSecret.length; i++) {
      newInitSecret[i] = random.nextInt(256);
    }

    final keySchedule = KeySchedule(_crypto.kdf);
    final newGroupContext = GroupContext(
      groupId: id,
      epoch: newEpoch,
      treeHash: newTreeHash,
      confirmedTranscriptHash: newConfirmedTranscriptHash,
    );
    final groupContextHash = newGroupContext.serialize();
    final newSecrets = await keySchedule.deriveEpochSecrets(
      initSecret: newInitSecret,
      groupContextHash: groupContextHash,
    );

    // Update state
    _state = _state.copyWith(
      context: newGroupContext,
      tree: newTree,
      members: newMembers,
      secrets: newSecrets,
    );

    // Save updated state
    await _storage.saveGroupState(_state);

    // Create commit
    final commit = Commit(proposals: removes, updatePath: updatePath);

    // Encrypt commit message
    final commitPlaintext = _serializeCommit(commit);
    final commitCiphertext = await _encryptCommit(commitPlaintext, newSecrets);

    return (commit, [commitCiphertext]);
  }

  /// Update self (post-compromise recovery)
  Future<(Commit, List<MlsCiphertext>)> updateSelf(
    UpdateProposal update,
  ) async {
    // Get local member's leaf index
    final localLeafIndex = _state.members.keys.first;
    final localMember = _state.members[localLeafIndex]!;

    // Create new tree with updated leaf
    final newTree = RatchetTree(List.from(_state.tree.nodes));

    // Find leaf node index (simplified - would use proper tree traversal)
    // For now, assume leaf nodes start at index (treeSize - 1) ~/ 2
    final treeSize = newTree.nodes.length;
    if (treeSize == 1) {
      // Single node tree
      newTree.nodes[0] = RatchetNode.withKeys(
        update.newHpkeInitKey,
        _state.leafHpkePrivateKey,
        null,
      );
    } else {
      final firstLeafIndex = (treeSize - 1) ~/ 2;
      final leafNodeIndex = firstLeafIndex + localLeafIndex.value;
      if (leafNodeIndex >= newTree.nodes.length) {
        throw MlsError('Invalid leaf index');
      }

      // Update leaf node with new HPKE key
      newTree.nodes[leafNodeIndex] = RatchetNode.withKeys(
        update.newHpkeInitKey,
        _state.leafHpkePrivateKey,
        null,
      );
    }

    // Compute update path from local leaf to root
    final updatePath = await _computeUpdatePath(localLeafIndex, newTree);

    // Advance epoch
    final newEpoch = _state.context.epoch + 1;
    final newTreeHash = await _computeTreeHash(newTree);
    final newConfirmedTranscriptHash = await _computeTranscriptHash(
      _state.context.confirmedTranscriptHash,
      updatePath,
    );

    // Derive new init secret and epoch secrets
    final random = Random.secure();
    final newInitSecret = Uint8List(32);
    for (int i = 0; i < newInitSecret.length; i++) {
      newInitSecret[i] = random.nextInt(256);
    }

    final keySchedule = KeySchedule(_crypto.kdf);
    final newGroupContext = GroupContext(
      groupId: id,
      epoch: newEpoch,
      treeHash: newTreeHash,
      confirmedTranscriptHash: newConfirmedTranscriptHash,
    );
    final groupContextHash = newGroupContext.serialize();
    final newSecrets = await keySchedule.deriveEpochSecrets(
      initSecret: newInitSecret,
      groupContextHash: groupContextHash,
    );

    // Update member's HPKE public key
    final updatedMembers = Map<LeafIndex, GroupMember>.from(_state.members);
    updatedMembers[localLeafIndex] = GroupMember(
      userId: localMember.userId,
      leafIndex: localLeafIndex,
      identityKey: localMember.identityKey,
      hpkePublicKey: update.newHpkeInitKey,
    );

    // Update state
    _state = _state.copyWith(
      context: newGroupContext,
      tree: newTree,
      members: updatedMembers,
      secrets: newSecrets,
    );

    // Save updated state
    await _storage.saveGroupState(_state);

    // Create commit
    final commit = Commit(proposals: [update], updatePath: updatePath);

    // Encrypt commit message
    final commitPlaintext = _serializeCommit(commit);
    final commitCiphertext = await _encryptCommit(commitPlaintext, newSecrets);

    return (commit, [commitCiphertext]);
  }

  /// Handle external commit (from network)
  Future<void> handleCommit(
    Commit commit,
    MlsCiphertext commitCiphertext,
  ) async {
    // Verify commit is for this group
    if (commitCiphertext.groupId.bytes.toString() != id.bytes.toString()) {
      throw InvalidCommit('Group ID mismatch');
    }

    // Verify epoch (commit should be for current or next epoch)
    if (commitCiphertext.epoch < _state.context.epoch) {
      throw InvalidCommit('Commit from past epoch');
    }

    // Decrypt commit (simplified - in production would verify signature)
    // For now, we'll process the commit directly

    // Process proposals
    final newTree = RatchetTree(List.from(_state.tree.nodes));
    final newMembers = Map<LeafIndex, GroupMember>.from(_state.members);

    for (final proposal in commit.proposals) {
      if (proposal is AddProposal) {
        final newLeafIndex = newTree.appendLeaf(
          RatchetNode.withKeys(proposal.hpkeInitKey, null, null),
        );
        newMembers[newLeafIndex] = GroupMember(
          userId: proposal.userId,
          leafIndex: newLeafIndex,
          identityKey: proposal.identityKey,
          hpkePublicKey: proposal.hpkeInitKey,
        );
      } else if (proposal is RemoveProposal) {
        final leafIndex = LeafIndex(proposal.removedLeafIndex);
        newTree.blankSubtree(leafIndex);
        newMembers.remove(leafIndex);
      } else if (proposal is UpdateProposal) {
        // Update affects the committing member's leaf
        // Simplified - would need to identify which member committed
      }
    }

    // Advance epoch
    final newEpoch = _state.context.epoch + 1;
    final newTreeHash = await _computeTreeHash(newTree);
    final newConfirmedTranscriptHash = await _computeTranscriptHash(
      _state.context.confirmedTranscriptHash,
      commit.updatePath ?? Uint8List(0),
    );

    // Derive new epoch secrets (simplified - would use init secret from update path)
    final random = Random.secure();
    final newInitSecret = Uint8List(32);
    for (int i = 0; i < newInitSecret.length; i++) {
      newInitSecret[i] = random.nextInt(256);
    }

    final keySchedule = KeySchedule(_crypto.kdf);
    final newGroupContext = GroupContext(
      groupId: id,
      epoch: newEpoch,
      treeHash: newTreeHash,
      confirmedTranscriptHash: newConfirmedTranscriptHash,
    );
    final groupContextHash = newGroupContext.serialize();
    final newSecrets = await keySchedule.deriveEpochSecrets(
      initSecret: newInitSecret,
      groupContextHash: groupContextHash,
    );

    // Update state
    _state = _state.copyWith(
      context: newGroupContext,
      tree: newTree,
      members: newMembers,
      secrets: newSecrets,
    );

    // Save updated state
    await _storage.saveGroupState(_state);
  }

  /// Join group from Welcome message
  static Future<MlsGroup> joinFromWelcome({
    required Welcome welcome,
    required mls_crypto.PrivateKey hpkePrivateKey,
    required mls_crypto.MlsCryptoProvider cryptoProvider,
    required MlsStorage storage,
    String? userId,
  }) async {
    final groupId = GroupId(welcome.groupId.bytes);

    // Extract the HPKE enc (first 32 bytes) and ciphertext from encryptedGroupSecrets
    // The sender prepends the 32-byte ephemeral public key to the sealed secrets
    const encLength = 32; // X25519 public key is 32 bytes
    final enc = welcome.encryptedGroupSecrets.sublist(0, encLength);
    final sealedGroupSecrets = welcome.encryptedGroupSecrets.sublist(encLength);
    
    // Decrypt group secrets using HPKE
    final hpkeContext = await cryptoProvider.hpke.setupBaseRecipient(
      enc: enc,
      recipientPrivateKey: hpkePrivateKey,
      info: Uint8List.fromList(utf8.encode('mls-welcome')),
    );
    
    // Decrypt the sealed group secrets
    final decryptedSecrets = await hpkeContext.open(
      ciphertext: sealedGroupSecrets,
      aad: Uint8List(0),
    );
    
    // Decrypt group info
    final decryptedGroupInfo = await hpkeContext.open(
      ciphertext: welcome.encryptedGroupInfo,
      aad: Uint8List(0),
    );
    
    // Deserialize group secrets
    final (initSecret, secrets, leafIndex) = _deserializeGroupSecrets(decryptedSecrets);
    
    // Deserialize group info
    final (context, tree, members) = _deserializeGroupInfo(decryptedGroupInfo);
    
    // Generate identity key pair for this member (if not provided)
    final identityKeyPair = await cryptoProvider.signatureScheme.generateKeyPair();
    
    // Create group state
    final state = GroupState(
      context: context,
      tree: tree,
      members: members,
      secrets: secrets,
      identityPrivateKey: identityKeyPair.privateKey,
      leafHpkePrivateKey: hpkePrivateKey,
    );
    
    // Save state
    await storage.saveGroupState(state);
    
    // Load or set group name
    final groupName = await storage.loadGroupName(groupId) ?? 
        (userId != null ? 'Group with $userId' : 'Joined Group');
    await storage.saveGroupName(groupId, groupName);

    return MlsGroup(groupId, groupName, state, cryptoProvider, storage);
  }

  /// Deserialize group secrets from Welcome message
  static (Uint8List, EpochSecrets, LeafIndex) _deserializeGroupSecrets(
    Uint8List data,
  ) {
    int offset = 0;
    
    // Read init secret
    final initSecretLength = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    final initSecret = data.sublist(offset, offset + initSecretLength);
    offset += initSecretLength;
    
    // Read epoch secrets
    final secretsLength = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    final secretsBytes = data.sublist(offset, offset + secretsLength);
    offset += secretsLength;
    final secrets = EpochSecrets.deserialize(secretsBytes);
    
    // Read leaf index
    final leafIndexValue = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    final leafIndex = LeafIndex(leafIndexValue);
    
    return (initSecret, secrets, leafIndex);
  }

  /// Deserialize group info from Welcome message
  static (GroupContext, RatchetTree, Map<LeafIndex, GroupMember>) _deserializeGroupInfo(
    Uint8List data,
  ) {
    int offset = 0;
    
    // Read context
    final contextLength = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    final contextBytes = data.sublist(offset, offset + contextLength);
    offset += contextLength;
    final context = GroupContext.deserialize(contextBytes);
    
    // Read tree
    final treeLength = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    final treeBytes = data.sublist(offset, offset + treeLength);
    offset += treeLength;
    final tree = RatchetTree.deserialize(treeBytes);
    
    // Read members
    final membersLength = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    final membersBytes = data.sublist(offset, offset + membersLength);
    final members = _deserializeMembersPublic(membersBytes);
    
    return (context, tree, members);
  }

  /// Deserialize members (public keys only)
  static Map<LeafIndex, GroupMember> _deserializeMembersPublic(Uint8List data) {
    final members = <LeafIndex, GroupMember>{};
    int offset = 0;
    
    // Read count
    final count = (data[offset] << 24) | 
        (data[offset + 1] << 16) | 
        (data[offset + 2] << 8) | 
        data[offset + 3];
    offset += 4;
    
    // Read each member
    for (int i = 0; i < count; i++) {
      // Leaf index
      final leafIndexValue = (data[offset] << 24) | 
          (data[offset + 1] << 16) | 
          (data[offset + 2] << 8) | 
          data[offset + 3];
      offset += 4;
      final leafIndex = LeafIndex(leafIndexValue);
      
      // User ID
      final userIdLength = (data[offset] << 24) | 
          (data[offset + 1] << 16) | 
          (data[offset + 2] << 8) | 
          data[offset + 3];
      offset += 4;
      final userIdBytes = data.sublist(offset, offset + userIdLength);
      offset += userIdLength;
      final userId = utf8.decode(userIdBytes);
      
      // Identity key
      final identityKeyLength = (data[offset] << 24) | 
          (data[offset + 1] << 16) | 
          (data[offset + 2] << 8) | 
          data[offset + 3];
      offset += 4;
      final identityKeyBytes = data.sublist(offset, offset + identityKeyLength);
      offset += identityKeyLength;
      // Create PublicKey from bytes (simplified - would use proper key type)
      final identityKey = DefaultPublicKey(identityKeyBytes);
      
      // HPKE public key
      final hpkeKeyLength = (data[offset] << 24) | 
          (data[offset + 1] << 16) | 
          (data[offset + 2] << 8) | 
          data[offset + 3];
      offset += 4;
      final hpkeKeyBytes = data.sublist(offset, offset + hpkeKeyLength);
      offset += hpkeKeyLength;
      final hpkePublicKey = DefaultPublicKey(hpkeKeyBytes);
      
      members[leafIndex] = GroupMember(
        userId: userId,
        leafIndex: leafIndex,
        identityKey: identityKey,
        hpkePublicKey: hpkePublicKey,
      );
    }
    
    return members;
  }

  // Helper methods

  /// Compute update path from leaf to root
  Future<Uint8List> _computeUpdatePath(
    LeafIndex leafIndex,
    RatchetTree tree,
  ) async {
    // Get direct path from leaf to root
    final path = tree.directPath(leafIndex);

    // Generate random secrets for each node in path
    final random = Random.secure();
    final pathSecrets = <Uint8List>[];
    for (final _ in path) {
      final secret = Uint8List(32);
      for (int i = 0; i < secret.length; i++) {
        secret[i] = random.nextInt(256);
      }
      pathSecrets.add(secret);
    }

    // Serialize path (simplified - in production would encrypt to copath nodes)
    final result = Uint8List(pathSecrets.length * 32);
    int offset = 0;
    for (final secret in pathSecrets) {
      result.setRange(offset, offset + 32, secret);
      offset += 32;
    }

    return result;
  }

  /// Compute tree hash
  Future<Uint8List> _computeTreeHash(RatchetTree tree) async {
    // Simplified tree hash - in production would hash tree structure
    final random = Random.secure();
    final hash = Uint8List(32);
    for (int i = 0; i < hash.length; i++) {
      hash[i] = random.nextInt(256);
    }
    return hash;
  }

  /// Compute transcript hash
  Future<Uint8List> _computeTranscriptHash(
    Uint8List previousHash,
    Uint8List updatePath,
  ) async {
    // Simplified transcript hash - in production would hash previous + commit
    final combined = Uint8List(previousHash.length + updatePath.length);
    combined.setRange(0, previousHash.length, previousHash);
    combined.setRange(previousHash.length, combined.length, updatePath);

    // Hash combined data (simplified - would use proper hash function)
    final random = Random.secure();
    final hash = Uint8List(32);
    for (int i = 0; i < hash.length; i++) {
      hash[i] = random.nextInt(256);
    }
    return hash;
  }

  /// Serialize commit
  Uint8List _serializeCommit(Commit commit) {
    // Simplified serialization
    final proposalsBytes = Uint8List(commit.proposals.length * 64);
    final updatePathBytes = commit.updatePath ?? Uint8List(0);
    final result = Uint8List(proposalsBytes.length + updatePathBytes.length);
    result.setRange(0, proposalsBytes.length, proposalsBytes);
    result.setRange(proposalsBytes.length, result.length, updatePathBytes);
    return result;
  }

  /// Encrypt commit message
  Future<MlsCiphertext> _encryptCommit(
    Uint8List plaintext,
    EpochSecrets secrets,
  ) async {
    final keySchedule = KeySchedule(_crypto.kdf);
    final senderLeafIndex = _state.members.keys.first.value;

    // Use handshake secret for commit encryption
    final keyMaterial = await keySchedule.deriveApplicationKeys(
      applicationSecret: secrets.handshakeSecret,
      senderIndex: senderLeafIndex,
      generation: 0,
    );

    final nonce = keyMaterial.nonce;
    final aad = Uint8List(0);
    final ciphertext = await _crypto.aead.seal(
      key: keyMaterial.key,
      nonce: nonce,
      plaintext: plaintext,
      aad: aad,
    );

    return MlsCiphertext(
      groupId: id,
      epoch: _state.context.epoch + 1,
      senderIndex: senderLeafIndex,
      nonce: nonce,
      ciphertext: ciphertext,
      contentType: MlsContentType.commit,
    );
  }

  /// Serialize group info (public state) for Welcome message
  Uint8List _serializeGroupInfo(
    GroupContext context,
    RatchetTree tree,
    Map<LeafIndex, GroupMember> members,
  ) {
    // Serialize: context + tree + members (public info only)
    final contextBytes = context.serialize();
    final treeBytes = tree.serialize();
    
    // Serialize members (public keys only)
    final membersBytes = _serializeMembersPublic(members);
    
    final totalLength = 4 + contextBytes.length + 4 + treeBytes.length + 4 + membersBytes.length;
    final result = Uint8List(totalLength);
    int offset = 0;
    
    _writeUint8List(result, offset, contextBytes);
    offset += 4 + contextBytes.length;
    
    _writeUint8List(result, offset, treeBytes);
    offset += 4 + treeBytes.length;
    
    _writeUint8List(result, offset, membersBytes);
    
    return result;
  }

  /// Serialize group secrets for Welcome message
  Uint8List _serializeGroupSecrets(
    Uint8List initSecret,
    EpochSecrets secrets,
    LeafIndex leafIndex,
  ) {
    // Serialize: init_secret + epoch_secrets + leaf_index
    final secretsBytes = secrets.serialize();
    final leafIndexBytes = Uint8List(4);
    leafIndexBytes[0] = (leafIndex.value >> 24) & 0xFF;
    leafIndexBytes[1] = (leafIndex.value >> 16) & 0xFF;
    leafIndexBytes[2] = (leafIndex.value >> 8) & 0xFF;
    leafIndexBytes[3] = leafIndex.value & 0xFF;
    
    final totalLength = 4 + initSecret.length + 4 + secretsBytes.length + 4 + leafIndexBytes.length;
    final result = Uint8List(totalLength);
    int offset = 0;
    
    _writeUint8List(result, offset, initSecret);
    offset += 4 + initSecret.length;
    
    _writeUint8List(result, offset, secretsBytes);
    offset += 4 + secretsBytes.length;
    
    _writeUint8List(result, offset, leafIndexBytes);
    
    return result;
  }

  /// Serialize members (public keys only)
  Uint8List _serializeMembersPublic(Map<LeafIndex, GroupMember> members) {
    // Format: count (4 bytes) + [leaf_index (4) + user_id_len (4) + user_id + identity_key_len (4) + identity_key + hpke_key_len (4) + hpke_key]*
    final count = members.length;
    var totalLength = 4; // count
    
    for (final member in members.values) {
      totalLength += 4; // leaf_index
      totalLength += 4 + utf8.encode(member.userId).length; // user_id
      totalLength += 4 + member.identityKey.bytes.length; // identity_key
      totalLength += 4 + member.hpkePublicKey.bytes.length; // hpke_key
    }
    
    final result = Uint8List(totalLength);
    int offset = 0;
    
    // Write count
    result[offset++] = (count >> 24) & 0xFF;
    result[offset++] = (count >> 16) & 0xFF;
    result[offset++] = (count >> 8) & 0xFF;
    result[offset++] = count & 0xFF;
    
    // Write each member
    for (final entry in members.entries) {
      final leafIndex = entry.key;
      final member = entry.value;
      
      // Leaf index
      result[offset++] = (leafIndex.value >> 24) & 0xFF;
      result[offset++] = (leafIndex.value >> 16) & 0xFF;
      result[offset++] = (leafIndex.value >> 8) & 0xFF;
      result[offset++] = leafIndex.value & 0xFF;
      
      // User ID
      final userIdBytes = utf8.encode(member.userId);
      _writeUint8List(result, offset, userIdBytes);
      offset += 4 + userIdBytes.length;
      
      // Identity key
      _writeUint8List(result, offset, member.identityKey.bytes);
      offset += 4 + member.identityKey.bytes.length;
      
      // HPKE public key
      _writeUint8List(result, offset, member.hpkePublicKey.bytes);
      offset += 4 + member.hpkePublicKey.bytes.length;
    }
    
    return result;
  }

  /// Helper to write Uint8List with length prefix
  void _writeUint8List(Uint8List target, int offset, Uint8List data) {
    final length = data.length;
    target[offset++] = (length >> 24) & 0xFF;
    target[offset++] = (length >> 16) & 0xFF;
    target[offset++] = (length >> 8) & 0xFF;
    target[offset++] = length & 0xFF;
    target.setRange(offset, offset + length, data);
  }
}

/// MLS Error base class
class MlsError implements Exception {
  final String message;
  MlsError(this.message);

  @override
  String toString() => 'MlsError: $message';
}

/// Decryption failed error
class DecryptionFailed extends MlsError {
  DecryptionFailed(super.message);
}

/// Invalid commit error
class InvalidCommit extends MlsError {
  InvalidCommit(super.message);
}

/// Group state mismatch error
class GroupStateMismatch extends MlsError {
  GroupStateMismatch(super.message);
}
