import 'dart:convert';
import 'dart:typed_data';

import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/backup/backup_models.dart';
import 'package:comunifi/services/db/backup_metadata.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart'
    show GroupId;
import 'package:comunifi/services/mls/messages/messages.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqflite.dart';

/// Service for backing up and restoring MLS groups to/from relay
///
/// Backups are encrypted using the user's personal MLS group and stored
/// as parameterized replaceable events (kind 30079) on the relay.
/// Each MLS group gets its own backup event identified by the 'd' tag.
class BackupService {
  final NostrService _nostrService;
  final MlsGroupTable _mlsGroupTable;
  final MlsSecureStorage _mlsSecureStorage;
  final BackupMetadataTable _backupMetadataTable;

  BackupService({
    required NostrService nostrService,
    required MlsGroupTable mlsGroupTable,
    required MlsSecureStorage mlsSecureStorage,
    required BackupMetadataTable backupMetadataTable,
  }) : _nostrService = nostrService,
       _mlsGroupTable = mlsGroupTable,
       _mlsSecureStorage = mlsSecureStorage,
       _backupMetadataTable = backupMetadataTable;

  /// Factory to create backup service from database
  static Future<BackupService> fromDatabase({
    required Database database,
    required NostrService nostrService,
  }) async {
    final mlsGroupTable = MlsGroupTable(database);
    final mlsSecureStorage = MlsSecureStorage();
    final backupMetadataTable = BackupMetadataTable(database);

    // Ensure backup metadata table exists
    try {
      await backupMetadataTable.create(database);
    } catch (_) {
      // Table might already exist
    }

    return BackupService(
      nostrService: nostrService,
      mlsGroupTable: mlsGroupTable,
      mlsSecureStorage: mlsSecureStorage,
      backupMetadataTable: backupMetadataTable,
    );
  }

  /// Backup a single MLS group to the relay
  ///
  /// [groupId] - The MLS group to backup
  /// [personalGroup] - The user's personal MLS group for encryption
  /// [keyPairs] - Nostr key pairs for signing the backup event
  /// [personalGroupIdHex] - Hex ID of the personal group (for tagging)
  Future<bool> backupMlsGroup({
    required GroupId groupId,
    required MlsGroup personalGroup,
    required NostrKeyPairs keyPairs,
    required String personalGroupIdHex,
  }) async {
    final groupIdHex = _groupIdToHex(groupId);

    try {
      debugPrint('Starting backup for group ${groupIdHex.substring(0, 8)}...');

      // Load group data from storage
      final publicStateBytes = await _mlsGroupTable.loadPublicState(groupId);
      if (publicStateBytes == null) {
        debugPrint('Cannot backup group: no public state found');
        return false;
      }

      final groupName =
          await _mlsGroupTable.loadGroupName(groupId) ?? 'Unknown';
      final (identityKey, hpkeKey) = await _mlsSecureStorage.loadPrivateKeys(
        groupId,
      );
      final epochSecretsBytes = await _mlsSecureStorage.loadEpochSecrets(
        groupId,
      );

      if (epochSecretsBytes == null) {
        debugPrint('Cannot backup group: no epoch secrets found');
        return false;
      }

      // Create backup payload
      final backup = MlsGroupBackup.fromRawData(
        groupId: groupIdHex,
        groupName: groupName,
        publicStateBytes: publicStateBytes,
        identityPrivateKeyBytes: identityKey?.bytes,
        hpkePrivateKeyBytes: hpkeKey?.bytes,
        epochSecretsBytes: epochSecretsBytes,
      );

      // Encrypt with personal group
      final backupJson = backup.toJsonString();
      final backupBytes = Uint8List.fromList(utf8.encode(backupJson));
      final ciphertext = await personalGroup.encryptApplicationMessage(
        backupBytes,
      );

      // Serialize ciphertext for event content
      final ciphertextJson = jsonEncode({
        'epoch': ciphertext.epoch,
        'senderIndex': ciphertext.senderIndex,
        'generation': ciphertext.generation,
        'nonce': ciphertext.nonce.toList(),
        'ciphertext': ciphertext.ciphertext.toList(),
      });

      // Create and publish backup event
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        [
          'd',
          groupIdHex,
        ], // Identifies which group this backs up (for parameterized replaceable)
        ['g', personalGroupIdHex], // Personal group used for encryption
      ], createdAt: createdAt);

      final backupEvent = NostrEvent.fromPartialData(
        kind: kindMlsGroupBackup,
        content: ciphertextJson,
        keyPairs: keyPairs,
        tags: tags,
        createdAt: createdAt,
      );

      final eventModel = NostrEventModel(
        id: backupEvent.id,
        pubkey: backupEvent.pubkey,
        kind: backupEvent.kind,
        content: backupEvent.content,
        tags: backupEvent.tags,
        sig: backupEvent.sig,
        createdAt: backupEvent.createdAt,
      );

      // Publish to relay
      await _nostrService.publishEvent(eventModel.toJson());

      // Update backup metadata
      await _backupMetadataTable.markBackedUp(
        groupIdHex,
        timestamp: backup.backupTimestamp,
        stateHash: _computeSimpleHash(publicStateBytes),
      );

      debugPrint(
        'Successfully backed up group ${groupIdHex.substring(0, 8)}...',
      );
      return true;
    } catch (e) {
      debugPrint('Failed to backup group ${groupIdHex.substring(0, 8)}...: $e');
      return false;
    }
  }

  /// Backup all MLS groups that need backup
  ///
  /// [groups] - List of MLS groups to potentially backup
  /// [personalGroup] - The user's personal MLS group for encryption
  /// [keyPairs] - Nostr key pairs for signing
  /// [personalGroupIdHex] - Hex ID of the personal group
  /// [forceAll] - If true, backup all groups regardless of dirty state
  Future<int> backupAllMlsGroups({
    required List<MlsGroup> groups,
    required MlsGroup personalGroup,
    required NostrKeyPairs keyPairs,
    required String personalGroupIdHex,
    bool forceAll = false,
  }) async {
    int backedUpCount = 0;

    for (final group in groups) {
      final groupIdHex = _groupIdToHex(group.id);

      // Skip the personal group itself (don't backup the encryption key source)
      if (groupIdHex == personalGroupIdHex) {
        continue;
      }

      // Check if backup is needed
      if (!forceAll) {
        final metadata = await _backupMetadataTable.getByGroupId(groupIdHex);
        if (metadata != null && !metadata.needsBackup) {
          continue;
        }
      }

      final success = await backupMlsGroup(
        groupId: group.id,
        personalGroup: personalGroup,
        keyPairs: keyPairs,
        personalGroupIdHex: personalGroupIdHex,
      );

      if (success) {
        backedUpCount++;
      }
    }

    debugPrint('Backed up $backedUpCount groups');
    return backedUpCount;
  }

  /// Restore MLS groups from relay backups
  ///
  /// [personalGroup] - The user's personal MLS group for decryption
  /// [userPubkey] - The user's Nostr pubkey to query their backups
  /// [personalGroupIdHex] - Hex ID of the personal group (to filter backups)
  ///
  /// Returns list of restored group backups (caller should restore to storage)
  Future<List<MlsGroupBackup>> fetchBackupsFromRelay({
    required MlsGroup personalGroup,
    required String userPubkey,
    required String personalGroupIdHex,
  }) async {
    final restoredBackups = <MlsGroupBackup>[];

    try {
      debugPrint('Fetching MLS group backups from relay...');

      // Query relay for backup events authored by this user
      // with matching personal group tag
      final events = await _nostrService.requestPastEvents(
        kind: kindMlsGroupBackup,
        authors: [userPubkey],
        tags: [personalGroupIdHex],
        tagKey: 'g',
        limit: 1000,
        useCache: false,
      );

      debugPrint('Found ${events.length} backup events');

      for (final event in events) {
        try {
          // Get the backed up group ID from 'd' tag
          String? backedUpGroupId;
          for (final tag in event.tags) {
            if (tag.isNotEmpty && tag[0] == 'd' && tag.length > 1) {
              backedUpGroupId = tag[1];
              break;
            }
          }

          if (backedUpGroupId == null) {
            debugPrint(
              'Backup event ${event.id.substring(0, 8)}... missing d tag',
            );
            continue;
          }

          // Decrypt the backup
          final ciphertextData = jsonDecode(event.content);
          final ciphertext = MlsCiphertext(
            groupId: personalGroup.id,
            epoch: ciphertextData['epoch'] as int,
            senderIndex: ciphertextData['senderIndex'] as int,
            generation: ciphertextData['generation'] as int? ?? 0,
            nonce: Uint8List.fromList(
              List<int>.from(ciphertextData['nonce'] as List),
            ),
            ciphertext: Uint8List.fromList(
              List<int>.from(ciphertextData['ciphertext'] as List),
            ),
            contentType: MlsContentType.application,
          );

          final decryptedBytes = await personalGroup.decryptApplicationMessage(
            ciphertext,
          );
          final backupJson = utf8.decode(decryptedBytes);
          final backup = MlsGroupBackup.fromJsonString(backupJson);

          restoredBackups.add(backup);
          debugPrint(
            'Decrypted backup for group ${backup.groupId.substring(0, 8)}...',
          );
        } catch (e) {
          debugPrint(
            'Failed to decrypt backup event ${event.id.substring(0, 8)}...: $e',
          );
          // Continue with other backups
        }
      }

      debugPrint(
        'Successfully restored ${restoredBackups.length} group backups',
      );
    } catch (e) {
      debugPrint('Failed to fetch backups from relay: $e');
    }

    return restoredBackups;
  }

  /// Mark a group as needing backup (called when group state changes)
  Future<void> markGroupDirty(String groupIdHex) async {
    await _backupMetadataTable.markDirty(groupIdHex);
  }

  /// Ensure a group is tracked for backup
  Future<void> trackGroup(String groupIdHex) async {
    await _backupMetadataTable.ensureExists(groupIdHex);
  }

  /// Get backup status summary
  Future<BackupStatus> getBackupStatus() async {
    return await _backupMetadataTable.getBackupStatus();
  }

  /// Get last backup time for a specific group
  Future<DateTime?> getLastBackupTime(String groupIdHex) async {
    final metadata = await _backupMetadataTable.getByGroupId(groupIdHex);
    return metadata?.lastBackupDateTime;
  }

  /// Check if any backups are pending
  Future<bool> hasPendingBackups() async {
    return await _backupMetadataTable.hasPendingBackups();
  }

  /// Get overall last backup time across all groups
  Future<DateTime?> getOverallLastBackupTime() async {
    return await _backupMetadataTable.getLastBackupTime();
  }

  /// Convert GroupId to hex string
  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Compute a simple hash for state comparison
  String _computeSimpleHash(Uint8List data) {
    // Simple hash for detecting changes - sum of bytes as hex
    int sum = 0;
    for (final byte in data) {
      sum = (sum + byte) & 0xFFFFFFFF;
    }
    return sum.toRadixString(16).padLeft(8, '0');
  }
}
