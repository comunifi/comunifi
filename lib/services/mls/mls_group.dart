import 'dart:typed_data';
import 'dart:math';
import 'crypto/crypto.dart' as mls_crypto;
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

  /// Encrypt an application message
  Future<MlsCiphertext> encryptApplicationMessage(Uint8List plaintext) async {
    // Get sender leaf index (simplified - in production would track local member)
    final senderLeafIndex = _state.members.keys.first;

    // Get and increment generation for this sender (prevents nonce reuse)
    final generation = _state.incrementGeneration(senderLeafIndex);

    // Derive application keys
    final keySchedule = KeySchedule(_crypto.kdf);
    final keyMaterial = await keySchedule.deriveApplicationKeys(
      applicationSecret: _state.secrets.applicationSecret,
      senderIndex: senderLeafIndex.value,
      generation: generation,
    );

    // Encrypt with AEAD
    final nonce = keyMaterial.nonce;
    final aad = Uint8List(0); // Simplified
    final ciphertext = await _crypto.aead.seal(
      key: keyMaterial.key,
      nonce: nonce,
      plaintext: plaintext,
      aad: aad,
    );

    return MlsCiphertext(
      groupId: id,
      epoch: _state.context.epoch,
      senderIndex: senderLeafIndex.value,
      nonce: nonce,
      ciphertext: ciphertext,
      contentType: MlsContentType.application,
    );
  }

  /// Decrypt an application message
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
    
    // Try decrypting with expected generation and nearby generations
    // This handles out-of-order messages or if we missed some messages
    final generationsToTry = [
      expectedGeneration,
      expectedGeneration + 1,
      expectedGeneration + 2,
      expectedGeneration - 1,
      expectedGeneration - 2,
    ].where((g) => g >= 0).toSet().toList()..sort();

    final keySchedule = KeySchedule(_crypto.kdf);
    final aad = Uint8List(0); // Simplified
    
    Exception? lastError;
    for (final generation in generationsToTry) {
      try {
        // Derive application keys for this generation
        final keyMaterial = await keySchedule.deriveApplicationKeys(
          applicationSecret: _state.secrets.applicationSecret,
          senderIndex: ciphertext.senderIndex,
          generation: generation,
        );

        // Verify nonce matches (since nonce is deterministic from generation)
        if (keyMaterial.nonce.toString() != ciphertext.nonce.toString()) {
          continue; // Wrong generation, try next
        }

        // Try to decrypt
        final decrypted = await _crypto.aead.open(
          key: keyMaterial.key,
          nonce: ciphertext.nonce,
          ciphertext: ciphertext.ciphertext,
          aad: aad,
        );

        // Success! Update our generation tracking
        _state.setGeneration(senderLeafIndex, generation);
        
        return decrypted;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        // Continue to next generation
      }
    }

    // If we get here, decryption failed for all generations
    throw DecryptionFailed(
      'Failed to decrypt message: ${lastError?.toString() ?? "Unknown error"}',
    );
  }

  /// Add members to the group
  Future<(Commit, List<MlsCiphertext>)> addMembers(
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

    // Create Welcome messages for new members (simplified)
    final welcomeMessages = <MlsCiphertext>[];

    return (commit, [commitCiphertext, ...welcomeMessages]);
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
  }) async {
    // Decrypt group secrets from Welcome (simplified)
    // In production, would decrypt using HPKE with hpkePrivateKey
    // For now, we'll use the group ID to load existing state

    // Extract group ID and reconstruct state (simplified)
    // In production, would properly deserialize group info
    final groupId = GroupId(welcome.groupId.bytes);

    // Load existing state if available
    var state = await storage.loadGroupState(groupId);
    if (state == null) {
      // Create minimal state from Welcome (simplified)
      // In production, would properly reconstruct from Welcome message
      throw MlsError(
        'Cannot join group - state reconstruction not fully implemented',
      );
    }

    // Load group name
    final groupName = await storage.loadGroupName(groupId) ?? 'Joined Group';

    return MlsGroup(groupId, groupName, state, cryptoProvider, storage);
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
